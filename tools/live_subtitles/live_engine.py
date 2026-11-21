"""Online acoustic alignment. Decisions contain only freshly observed segments.

Acoustic reference text is existing English subtitles, never generated captions.
Verified media PTS may resume the same asset after an insertion. Clock resets,
asset changes and failed acoustic checks invalidate that calibration.
"""
import difflib
from bisect import bisect_left, bisect_right
from collections import Counter
import json
from pathlib import Path
import re
import statistics
import shutil
import subprocess
import threading
import time
import unicodedata

from live_media import Collector, playlist
from subtitle_catalog import discover, norm


def acoustic_norm(text):
    # SDH speaker names, sound descriptions, and ASS styling are not spoken.
    # Strip them only from acoustic reference tokens; display cues stay intact.
    text=re.sub(r'\{\\[^}]+\}', '', text)
    text=re.sub(r'\[[^\]]{0,160}\]', '', text)
    text=re.sub(r'^\s*\([^)]{0,80}\)\s*', '', text, flags=re.M)
    text=re.sub(r'^\s*-?\s*[A-Z][A-Z .\x27-]{1,30}:\s*', '', text, flags=re.M)
    expansions = {"there's": "there is", "theres": "there is", "thats": "that is", "dont": "do not", "cant": "can not", "it's": "it is", "that's": "that is",
        "what's": "what is", "we're": "we are", "you're": "you are",
        "they're": "they are", "i'm": "i am", "don't": "do not",
        "doesn't": "does not", "didn't": "did not", "can't": "can not",
        "cannot": "can not", "isn't": "is not", "wasn't": "was not",
        "won't": "will not", "i'll": "i will", "we'll": "we will"}
    return [part for token in norm(text.replace('’', "'"))
            for part in expansions.get(token, token).split()]


def sparse_word_anchors(cues, cue_words, asr, owners, timeline, rate, existing):
    """Require unique cue placements from ordered words with gaps and matching times."""
    starts = {}
    for index, token in enumerate(asr):
        if owners[index]['probability'] >= .75:
            starts.setdefault(token, []).append(index)
    possible = list(existing)
    anchored = {anchor['cue'] for anchor in existing}
    for cue in cues:
        values = cue_words[cue['index']]
        if cue['index'] in anchored or len(values) < 4 or '♪' in cue['text']:
            continue
        distinctive = set(token for token in values[1:10] if len(token) >= 4)
        if len(distinctive) < 2:
            continue
        for index in starts.get(values[0], ()):
            onset = owners[index]['start']
            matched = set()
            reference = 1
            for following in range(index + 1, min(len(asr), index + 13)):
                word = owners[following]
                if word['start'] - onset > min(4., cue['end'] - cue['start'] + .45):
                    break
                token = asr[following]
                if word['probability'] < .75 or token not in distinctive or token in matched:
                    continue
                found = next((i for i in range(reference, min(10, len(values))) if values[i] == token), None)
                if found is None:
                    continue
                reference = found + 1
                matched.add(token)
            if len(matched) < 2:
                continue
            observed = timeline + onset
            possible.append(dict(cue=cue['index'], subtitleStart=cue['start'],
                                 asrStart=observed, offset=cue['start'] - rate * observed,
                                 words=len(matched) + 1, sparseWords=True))
    cue_candidates = {}
    for anchor in possible:
        if anchor.get('sparseWords'):
            cue_candidates.setdefault(anchor['asrStart'], set()).add(anchor['cue'])
    groups = {}
    ordered = sorted(
        (a for a in possible if not a.get('sparseWords') or len(cue_candidates[a['asrStart']]) == 1),
        key=lambda anchor: anchor['offset'],
    )
    offsets = [anchor['offset'] for anchor in ordered]
    for center in offsets:
        first = bisect_right(offsets, center - .55)
        last = bisect_left(offsets, center + .55)
        if last - first < 3:
            continue
        consistent = []
        for anchor in sorted(ordered[first:last], key=lambda item: item['asrStart']):
            if consistent and (anchor['asrStart'] - consistent[-1]['asrStart'] < .45 or
                               anchor['subtitleStart'] - consistent[-1]['subtitleStart'] < .45):
                continue
            consistent.append(anchor)
        if len(consistent) >= 3 and consistent[-1]['asrStart'] - consistent[0]['asrStart'] >= 4:
            groups[tuple((a['cue'], a['asrStart']) for a in consistent)] = consistent
    ranked = sorted(groups.values(), key=len, reverse=True)
    if not ranked:
        return []
    best = ranked[0]
    offset = statistics.median(anchor['offset'] for anchor in best)
    if any(len(other) >= len(best) - 1 and
           abs(statistics.median(a['offset'] for a in other) - offset) >= .9
           for other in ranked[1:]):
        return []
    return best


def short_cue_clock_evidence(anchors):
    """Short CJK lines require more independent onsets and exact characters."""
    unique = {a['cue']: a for a in anchors}
    values = list(unique.values())
    return (any(a.get('shortCuePrefix') for a in values) and len(values) >= 6
            and sum(min(8, a['words']) for a in values) >= 32
            and max(a['asrStart'] for a in values) - min(a['asrStart'] for a in values) >= 12
            and max(abs(a['offset']-statistics.median(x['offset'] for x in values))
                    for a in values) <= .5)


def short_cue_clock_cluster(anchors, fresh_ids=None):
    groups = {}
    for center in anchors:
        group = [a for a in anchors if abs(a['offset']-center['offset']) < .5]
        if (short_cue_clock_evidence(group) and
                (fresh_ids is None or any(a['cue'] in fresh_ids for a in group))):
            groups[tuple(sorted((a['cue'],a['asrStart']) for a in group))] = group
    ranked = sorted(groups.values(),key=lambda group:len({a['cue'] for a in group}),reverse=True)
    if not ranked:return []
    best=ranked[0];offset=statistics.median(a['offset'] for a in best)
    if any(len({a['cue'] for a in other})>=len({a['cue'] for a in best})-1 and
           abs(statistics.median(a['offset'] for a in other)-offset)>=.9 for other in ranked[1:]):
        return []
    return best


def align(words, cues, timeline, *, rate=1., language='en'):
    def tokenize(text):
        if language == 'en':
            return acoustic_norm(text)
        text=unicodedata.normalize('NFKC',text).casefold()
        text=re.sub(r'\{\\[^}]+\}|\[[^\]]{0,160}\]', '', text)
        if language in ('ja','ko','zh-CN','zh-TW'):
            return [ch for ch in text if ch.isalnum()]
        return re.findall(r'[^\W_]+',text)

    minimum=8 if language in ('ja','ko','zh-CN','zh-TW') else 4
    tokens, firsts, asr, owners = [], {}, [], []
    cue_words={c['index']:tokenize(c['text']) for c in cues}
    for cue in cues:
        values = cue_words[cue['index']] if '♪' not in cue['text'] else []
        if values:
            firsts[len(tokens)] = cue
            tokens.extend(values)
    for word in words:
        for token in tokenize(word['word']):
            asr.append(token); owners.append(word)
    prefixes={n:Counter(tuple(values[:n]) for values in cue_words.values() if len(values)>=n) for n in range(4,9)}
    anchors = []
    if language in ('ja','ko','zh-CN','zh-TW'):
        # A short subtitle can be a complete utterance. Do not require eight
        # characters inside every line; retain exact unique whole-line matches
        # for the separate, stricter multi-onset clock proof below.
        observed_short = {count: {} for count in range(4, 8)}
        for count, placements in observed_short.items():
            for observed in range(len(asr)-count+1):
                placements.setdefault(tuple(asr[observed:observed+count]), []).append(observed)
        for cue in firsts.values():
            values = cue_words[cue['index']]
            count = len(values)
            if not 4 <= count < 8 or prefixes[count][tuple(values)] != 1:
                continue
            for observed in observed_short[count].get(tuple(values), ()):
                if observed and owners[observed] is owners[observed-1]:
                    continue
                matched_owners = owners[observed:observed+count]
                if (matched_owners[0]['probability'] < .7 or
                        statistics.mean(w['probability'] for w in matched_owners) < .8):
                    continue
                onset = timeline + matched_owners[0]['start']
                anchors.append(dict(cue=cue['index'],subtitleStart=cue['start'],asrStart=onset,
                    offset=cue['start']-rate*onset,words=count,shortCuePrefix=True,sparseWords=True))
        placements={}
        for anchor in anchors:placements.setdefault(anchor['cue'],set()).add(anchor['asrStart'])
        anchors=[a for a in anchors if len(placements[a['cue']])==1]
    for match in difflib.SequenceMatcher(None, tokens, asr, autojunk=False).get_matching_blocks():
        if match.size < minimum:
            continue
        for index in range(match.a, match.a + match.size - 2):
            cue = firsts.get(index)
            if cue is None:
                continue
            values=cue_words[cue['index']]
            required=next((n for n in dict.fromkeys((4,6,8,min(len(values),8))) if n>=minimum and len(values)>=n and prefixes[n][tuple(values[:n])]==1),None)
            remaining=match.a+match.size-index
            if required is None or remaining<required:
                continue
            owner_index=match.b+index-match.a
            if statistics.mean(w['probability'] for w in owners[owner_index:owner_index+required])<.65:
                continue
            word = owners[owner_index]
            matched=min(remaining,len(values))
            probability=statistics.mean(w['probability'] for w in owners[owner_index:owner_index+matched])
            if word['probability'] < .55 and not (word['probability']>=.4 and matched>=8 and probability>=.8):
                continue
            onset = timeline + word['start']
            anchors.append(dict(cue=cue['index'], subtitleStart=cue['start'], asrStart=onset,
                                offset=cue['start'] - rate*onset, words=min(remaining,len(values))))
    # Recover a single ASR word substitution only in a unique six-token
    # prefix. The first two words and five of six words must agree, and a
    # second reference within one substitution makes the match ambiguous.
    references=[(cue,cue_words[cue['index']]) for cue in cues if language=='en' and len(cue_words[cue['index']])>=6]
    # Both fuzzy checks require identical first two tokens. Index this exact
    # prerequisite once instead of comparing every subtitle with every other
    # subtitle on each viewer observation.
    reference_prefixes={}
    for cue,values in references:
        reference_prefixes.setdefault(tuple(values[:2]),[]).append((cue,values))
    observed_prefixes={}
    for i in range(len(asr)-5):
        observed_prefixes.setdefault(tuple(asr[i:i+2]),[]).append(i)
    anchored={a['cue'] for a in anchors}
    for cue,values in references:
        if cue['index'] in anchored:continue
        prefix=values[:6]
        neighbors=[other for other,v in reference_prefixes[tuple(prefix[:2])] if sum(a!=b for a,b in zip(prefix,v[:6]))<=1]
        if len(neighbors)!=1:continue
        for i in observed_prefixes.get(tuple(prefix[:2]),()):
            if sum(a!=b for a,b in zip(prefix,asr[i:i+6]))>1:continue
            if owners[i]['probability']<.6 or statistics.mean(w['probability'] for w in owners[i:i+6])<.8:continue
            onset=timeline+owners[i]['start']
            anchors.append(dict(cue=cue['index'],subtitleStart=cue['start'],asrStart=onset,
                offset=cue['start']-rate*onset,words=5,fuzzyPrefix=True))
            anchored.add(cue['index']);break
    strong = [a for a in anchors if not (a.get('shortCuePrefix'))]
    cluster = max(([a for a in strong if abs(a['offset'] - c['offset']) < .9] for c in strong),
                  key=len, default=[])
    if len({a['cue'] for a in cluster}) >= 3 and max(a['asrStart'] for a in cluster) - min(a['asrStart'] for a in cluster) >= 4:
        return statistics.median(a['offset'] for a in cluster), cluster
    short_cluster = short_cue_clock_cluster(anchors)
    if short_cluster:
        return statistics.median(a['offset'] for a in short_cluster), short_cluster
    if language == 'en':
        sparse = sparse_word_anchors(cues, cue_words, asr, owners, timeline, rate, anchors)
        if sparse:
            return statistics.median(a['offset'] for a in sparse), sparse
    return None, anchors



def fit_clock_rate(points,current_rate=1.):
    """Require multi-window evidence before accepting a standard FPS ratio."""
    if len(points)<8:return None
    xs=[p['sourcePts'] for p in points];origin=min(xs)
    if max(xs)-origin<45 or len({int((x-origin)//15) for x in xs})<3:return None
    models=[]
    for rate in (1.0,24/25,(24000/1001)/25,25/24,25/(24000/1001)):
        intercept=statistics.median(p['subtitleStart']-rate*p['sourcePts'] for p in points)
        errors=sorted(abs(p['subtitleStart']-rate*p['sourcePts']-intercept) for p in points)
        models.append(dict(rate=rate,intercept=intercept,error=statistics.median(errors),p90=errors[int((len(errors)-1)*.9)]))
    best=min(models,key=lambda m:m['error'])
    baseline=min(models,key=lambda m:abs(m['rate']-current_rate))
    if abs(best['rate']-current_rate)<1e-8 or best['error']>.35 or best['p90']>.75 or baseline['error']-best['error']<.2:return None
    return best



def clock_rate_confident(points,rate,intercept):
    if len(points)<8:return False
    xs=[p['sourcePts'] for p in points];origin=min(xs)
    if max(xs)-origin<45 or len({int((x-origin)//15) for x in xs})<3:return False
    errors=sorted(abs(p['subtitleStart']-rate*p['sourcePts']-intercept) for p in points)
    return bool(statistics.median(errors)<=.35 and errors[int((len(errors)-1)*.9)]<=.75)

def mapped_cues(cues,row,pts,rate,intercept):
    movie_start=rate*pts+intercept;result=[]
    for c in cues:
        start=row['timelineStart']+(c['start']-movie_start)/rate
        end=row['timelineStart']+(c['end']-movie_start)/rate
        if end>row['timelineStart'] and start<row['timelineEnd']:
            result.append(dict(index=c['index'],start=max(start,row['timelineStart']),
                               end=min(end,row['timelineEnd']),text=c['text']))
    return result

def media_pts(row, ffmpeg, root):
    path = root / 'analysis' / ('pts-' + str(row['sequence']) + '.m3u8')
    path.write_text(playlist([row], end=True))
    probe = shutil.which('ffprobe')
    if probe:
        result = subprocess.run([probe, '-v', 'error', '-protocol_whitelist', 'file,crypto,data',
            '-allowed_extensions', 'ALL', '-select_streams', 'v:0', '-show_entries', 'packet=pts_time',
            '-read_intervals', '%+#1', '-of', 'json', str(path)], capture_output=True, text=True, timeout=8)
        return float(json.loads(result.stdout)['packets'][0]['pts_time'])
    result = subprocess.run([ffmpeg, '-hide_banner', '-copyts', '-protocol_whitelist', 'file,crypto,data',
                             '-allowed_extensions', 'ALL', '-i', str(path), '-an', '-vf', 'showinfo',
                             '-frames:v', '1', '-f', 'null', '-'], capture_output=True, text=True, timeout=12)
    match = re.search(r'n:\s*0\s+pts:.*?pts_time:([^ ]+)', result.stderr)
    if match is None:
        raise ValueError('video_pts_unavailable')
    return float(match[1])


def transcribe(rows, model, ffmpeg, root):
    path = root / 'analysis' / (str(rows[-1]['sequence']) + '.m3u8')
    path.write_text(playlist(rows, end=True))
    wav = path.with_suffix('.wav')
    subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-protocol_whitelist', 'file,crypto,data',
                    '-allowed_extensions', 'ALL', '-i', str(path), '-vn', '-ac', '1', '-ar', '16000',
                    '-y', str(wav)], timeout=20, capture_output=True, check=True)
    segments, _ = model.transcribe(str(wav), language='en', word_timestamps=True, beam_size=1, vad_filter=True)
    words = [dict(start=w.start, end=w.end, word=w.word, probability=w.probability)
             for s in segments for w in (s.words or [])]
    wav.unlink(missing_ok=True)
    return words


class Engine:
    def __init__(self, source, programme, root, model, ffmpeg, *, candidates=None, preferred_language='en', synchronous_analysis=False, subtitle_cache=None):
        self.root = Path(root); (self.root / 'analysis').mkdir(parents=True, exist_ok=True)
        self.collector = Collector(source, self.root, seconds=0)
        self.programme, self.model, self.ffmpeg = programme, model, ffmpeg
        self.lock = threading.RLock(); self.decisions = {}; self.candidates = candidates
        self.subtitle_cache = subtitle_cache
        self.discovery_error = False
        self.unmatched_windows = 0
        self.acquisition_exhausted = False
        self.last_discovery = 0
        self.discovery_thread = None
        self.preferred_language = preferred_language
        self.state = 'ACQUIRING'; self.last_sequence = -1
        self.rate = 1.0; self.rate_verified = False; self.clock_points = {}; self.clock_key = None
        self.k = None; self.verified_asset = None; self.last_pts_end = None
        self.pause = None; self.returned = None; self.resume = None; self.holdout = {}
        self.calibration_cues = set()
        self.errors = []
        self.controller_stop = threading.Event()
        self.reference = None
        self.analysis_thread = None
        self.synchronous_analysis = synchronous_analysis
        self.generation = 0
        self.active_asset = None
        self.active_movie = None

    def event(self, kind, **facts):
        item = dict(event=kind, **{'wall': time.time(), **facts})
        with (self.root / 'controller-events.jsonl').open('a') as file:
            file.write(json.dumps(item) + '\n')

    def start(self, collect=True):
        if collect:
            threading.Thread(target=self.collector.run, daemon=True).start()
        threading.Thread(target=self.run, daemon=True).start()

    def discover_subtitles(self):
        self.last_discovery = time.monotonic()
        self.discovery_error = False
        try:
            if self.candidates is None:
                if self.subtitle_cache is not None:
                    self.candidates = self.subtitle_cache.get_or_discover(self.programme, self.root/'subtitles', discover,
                                                                         requested_language=self.preferred_language)
                else:
                    self.candidates = discover(self.programme['title'], self.programme['year'], self.root / 'subtitles',
                                               requested_language=self.preferred_language, imdb_id=self.programme.get('imdbId'))
            self.candidates.sort(key=lambda c: (self.preferred_language not in c['tracks'], -len(c['tracks'])))
            self.event('subtitle_discovery', candidates=[dict(page=c['page'], languages=list(c['tracks']), cacheHit=bool(c.get('cacheHit'))) for c in self.candidates])
            if not self.candidates:
                self.event('no_existing_english_reference')
        except Exception as error:
            self.discovery_error = True
            self.candidates = []; self.event('subtitle_discovery_error', errorType=type(error).__name__)

    def run(self):
        self.discover_subtitles()
        run, last_analysis = [], -100.
        while not self.collector.stop.is_set() and not self.controller_stop.is_set():
            retry_after = 60 if self.discovery_error else 900
            if (not self.candidates and time.monotonic()-self.last_discovery >= retry_after and
                    (self.discovery_thread is None or not self.discovery_thread.is_alive())):
                self.candidates = None
                self.discovery_thread = threading.Thread(target=self.discover_subtitles, daemon=True)
                self.discovery_thread.start()
            fresh = [r for r in self.collector.snapshot() if r['sequence'] > self.last_sequence]
            for row in fresh:
                self.last_sequence = row['sequence']
                matches = row['contentId'] == self.programme['movieId'] and not row.get('declaredAd',False)
                old_state = self.state
                if self.active_asset != row['asset'] or self.active_movie != matches or row['sequenceGap']:
                    with self.lock:
                        self.generation += 1
                        self.active_asset, self.active_movie = row['asset'], matches
                        if row['sequenceGap']:
                            self.k = None; self.verified_asset = None
                pts = None
                if matches:
                    try:
                        pts = media_pts(row, self.ffmpeg, self.root)
                    except Exception as error:
                        self.event('pts_error', sequence=row['sequence'], errorType=type(error).__name__)
                eligible = matches and pts is not None and not row['sequenceGap']
                with self.lock:
                    # An asset change must be acoustically verified, even if CAID or movie title remains.
                    known_asset = self.verified_asset == row['asset']
                    if not eligible or (self.state == 'LOCKED' and not known_asset):
                        if self.state == 'LOCKED':
                            self.pause = dict(start=row['timelineStart'], observedWall=row['observedWall'], sequence=row['sequence'])
                            self.returned = self.resume = None; self.holdout = {}
                            self.event('caption_pause', **self.pause, reason='unknown_or_changed_media')
                        self.state = 'SUSPENDED'; run = []
                    if eligible:
                        if self.state == 'SUSPENDED':
                            if self.last_pts_end is not None and abs(pts-self.last_pts_end)>.16:
                                self.clock_points.clear();self.rate_verified=False
                            self.state = 'ACQUIRING'; run = []
                            if self.pause is not None and self.returned is None:
                                self.returned = dict(start=row['timelineStart'], observedWall=row['observedWall'], sequence=row['sequence'])
                                self.event('movie_return_candidate', **self.returned)
                            if (known_asset and self.rate_verified and self.k is not None and self.last_pts_end is not None
                                    and abs(pts - self.last_pts_end) <= .16):
                                self.state = 'LOCKED'
                                self.resume = dict(timeline=row['timelineStart'], wall=time.time(), mode='verified_pts_continuity')
                                self.event('fast_clock_resume', **self.resume, sequence=row['sequence'],
                                           continuityErrorSeconds=pts - self.last_pts_end,
                                           observedRecoverySeconds=time.time() - row['observedWall'])
                        if self.state == 'LOCKED' and old_state == 'LOCKED' and self.last_pts_end is not None and abs(pts - self.last_pts_end) > .2:
                            self.clock_points.clear();self.rate_verified=False
                            self.state = 'ACQUIRING'; self.k = None; self.verified_asset = None; run = []; self.generation += 1
                            self.event('clock_discontinuity', sequence=row['sequence'], errorSeconds=pts - self.last_pts_end)
                        run.append(row)
                        self.last_pts_end = pts + row['duration']
                        if (self.candidates and (self.analysis_thread is None or not self.analysis_thread.is_alive())
                                and row['timelineEnd'] - last_analysis >= 12 and sum(r['duration'] for r in run) >= 12):
                            window, length = [], 0
                            for previous in reversed(run):
                                window.insert(0, previous); length += previous['duration']
                                if length >= 24:
                                    break
                            if self.synchronous_analysis:
                                self.analyze(window, row, pts, self.generation)
                            else:
                                self.analysis_thread = threading.Thread(target=self.analyze,
                                    args=(window, row, pts, self.generation), daemon=True)
                                self.analysis_thread.start()
                            last_analysis = row['timelineEnd']
                    reference = self.reference
                    tracks = []
                    offset = self.rate*pts + self.k - row['timelineStart'] if self.state == 'LOCKED' and self.k is not None and pts is not None else None
                    if offset is not None and reference:
                        for language, cues in reference['tracks'].items():
                            emitted = mapped_cues(cues,row,pts,self.rate,self.k)
                            if emitted:
                                tracks.append(dict(language=language, verified=True, cues=emitted))
                    decision = dict(start=row['timelineStart'], end=row['timelineEnd'], state=self.state,
                                    program=self.programme['movieId'], asset=row['asset'], tracks=tracks,
                                    sequence=row['sequence'], generatedWall=time.time(), pts=pts, offset=offset, rate=self.rate, clockGeneration=self.generation)
                    with self.lock:
                        self.decisions[row['sequence']] = decision
                        cutoff=row['timelineEnd']-7200
                        self.decisions={sequence:d for sequence,d in self.decisions.items() if d['end']>=cutoff}
                        with (self.root / 'decisions.jsonl').open('a') as file:
                            file.write(json.dumps(decision, ensure_ascii=False) + '\n')
                    (self.root / 'status.json').write_text(json.dumps(dict(state=self.state, lastSequence=self.last_sequence,
                        timeline=row['timelineEnd'], pause=self.pause, returned=self.returned, resume=self.resume,
                        holdout=list(self.holdout.values()), subtitleCandidates=len(self.candidates or []),
                        unmatchedWindows=self.unmatched_windows, acquisitionExhausted=self.acquisition_exhausted,clockRate=self.rate,clockRateVerified=self.rate_verified)))
            self.collector.stop.wait(.15)

    def retime_decisions(self, asset, minimum_start=float('-inf'), clock_origin=None):
        for decision in self.decisions.values():
            if (decision['state'] not in ('LOCKED','ACQUIRING') or decision['asset']!=asset
                    or decision.get('clockGeneration')!=self.generation or decision.get('pts') is None
                    or decision['start']<minimum_start):continue
            if clock_origin is not None and abs(decision['pts']-decision['start']-clock_origin)>.2:continue
            row=dict(timelineStart=decision['start'],timelineEnd=decision['end'])
            tracks=[]
            for language,cues in self.reference['tracks'].items():
                emitted=mapped_cues(cues,row,decision['pts'],self.rate,self.k)
                if emitted:tracks.append(dict(language=language,verified=True,cues=emitted))
            decision.update(state='LOCKED',tracks=tracks,rate=self.rate,recalibratedWall=time.time(),offset=self.rate*decision['pts']+self.k-decision['start'])

    def analyze(self, window, row, pts, generation):
        started = time.time()
        try:
            words = transcribe(window, self.model, self.ffmpeg, self.root)
            trial = [self.reference] if self.reference else self.candidates
            observations = []
            for candidate in trial:
                found, anchors = align(words, candidate['tracks']['en'], window[0]['timelineStart'])
                observations.append(dict(page=candidate['page'], offset=found, anchors=anchors))
                if found is None:
                    continue
                with self.lock:
                    if (self.controller_stop.is_set() or generation != self.generation
                            or self.active_asset != row['asset'] or self.state == 'SUSPENDED'):
                        self.event('stale_acoustic_result_rejected', sequence=row['sequence'])
                        break
                    key=(candidate['page'],row['asset'])
                    same_clock=key==self.clock_key
                    if not same_clock:self.clock_points={};self.clock_key=key
                    for anchor in anchors:
                        self.clock_points[anchor['cue']]=dict(cue=anchor['cue'],sourcePts=pts+anchor['asrStart']-row['timelineStart'],
                                                            subtitleStart=anchor['subtitleStart'],asrStart=anchor['asrStart'])
                    self.clock_points={cue:p for cue,p in self.clock_points.items() if p['asrStart']>=row['timelineEnd']-600}
                    points=sorted(self.clock_points.values(),key=lambda p:p['asrStart'])[-128:]
                    proposal=fit_clock_rate(points,self.rate)
                    candidate_rate=proposal['rate'] if proposal else (self.rate if same_clock else 1.0)
                    candidate_k=proposal['intercept'] if proposal else statistics.median(
                        a['subtitleStart']-candidate_rate*(pts+a['asrStart']-row['timelineStart']) for a in anchors)
                    if self.state != 'LOCKED':
                        self.unmatched_windows = 0; self.acquisition_exhausted = False
                        self.rate = candidate_rate
                        self.reference = candidate; self.k = candidate_k; self.verified_asset = row['asset']; self.state = 'LOCKED'
                        self.rate_verified=clock_rate_confident(points,self.rate,self.k)
                        self.retime_decisions(row['asset'],window[0]['timelineStart'],pts-row['timelineStart'])
                        self.calibration_cues = {a['cue'] for a in (points if proposal else anchors)}
                        if self.returned:
                            latest=self.collector.snapshot()[-1]
                            self.resume = dict(timeline=latest['timelineEnd'], wall=time.time(), mode='fresh_acoustic_lock')
                        self.event('acoustic_lock', timeline=row['timelineEnd'], wallSeconds=time.time()-started,
                                   subtitleMinusPts=self.k, rate=self.rate, anchors=anchors, afterReturn=bool(self.returned))
                    else:
                        offset=self.k+self.rate*pts-row['timelineStart']
                        residuals=[a['subtitleStart']-(self.rate*(pts+a['asrStart']-row['timelineStart'])+self.k) for a in anchors]
                        self.event('acoustic_validation', timeline=row['timelineEnd'], anchors=anchors,
                                   residualSeconds=residuals,activeOffset=offset,rate=self.rate,afterReturn=bool(self.returned))
                        if proposal and abs(proposal['rate']-self.rate)>.0005 and (self.rate==1 or abs(statistics.median(residuals))>.5):
                            previous_rate=self.rate;self.rate=proposal['rate'];self.k=proposal['intercept']
                            self.calibration_cues={a['cue'] for a in points};self.holdout={}
                            self.rate_verified=True
                            self.retime_decisions(row['asset'],window[0]['timelineStart'],pts-row['timelineStart'])
                            self.event('clock_rate_calibrated',previousRate=previous_rate,rate=self.rate,intercept=self.k,
                                       anchorCount=len(points),spanSeconds=max(p['sourcePts'] for p in points)-min(p['sourcePts'] for p in points),
                                       medianAbsoluteResidual=proposal['error'])
                        elif abs(statistics.median(residuals))>.9:
                            self.state='ACQUIRING';self.k=None;self.rate_verified=False;self.verified_asset=None;self.generation+=1;self.decisions.clear()
                            self.event('acoustic_calibration_invalidated', deviationSeconds=statistics.median(residuals))
                        else:
                            self.rate_verified=clock_rate_confident(points,self.rate,self.k)
                        if self.returned and self.state=='LOCKED':
                            for anchor,residual in zip(anchors,residuals):
                                if anchor['asrStart']>=self.returned['start'] and anchor['cue'] not in self.calibration_cues:
                                    self.holdout[anchor['cue']]=dict(**anchor,errorSeconds=residual)
                break
            with self.lock:
                if (not self.reference and generation == self.generation and not self.controller_stop.is_set()
                        and self.state != 'SUSPENDED' and self.active_asset == row['asset']
                        and len(words) >= 12 and observations and all(o['offset'] is None for o in observations)):
                    self.unmatched_windows += 1
                    if self.unmatched_windows >= 3 and not self.acquisition_exhausted:
                        self.acquisition_exhausted = True
                        self.event('subtitle_acquisition_exhausted', attempts=self.unmatched_windows,
                                   candidates=len(trial), reason='speech_did_not_match_any_file')
            (self.root/'analysis'/(str(row['sequence'])+'.json')).write_text(json.dumps(dict(
                observedWall=time.time(),timelineStart=window[0]['timelineStart'],timelineEnd=row['timelineEnd'],
                processSeconds=time.time()-started,observations=observations,words=words)))
        except Exception as error:
            self.event('analysis_error',sequence=row['sequence'],errorType=type(error).__name__)

    def windows(self, origin=0):
        with self.lock:
            return [{**d, 'start': d['start'] - origin, 'end': d['end'] - origin,
                     'tracks': [{**t, 'cues': [{**c, 'start': c['start'] - origin, 'end': c['end'] - origin}
                                             for c in t['cues']]} for t in d['tracks']]}
                    for d in self.decisions.values() if d['end'] > origin][-4500:]
