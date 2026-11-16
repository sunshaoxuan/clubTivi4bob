"""Online acoustic alignment. Decisions contain only freshly observed segments.

Acoustic reference text is existing English subtitles, never generated captions.
Verified media PTS may resume the same asset after an insertion. Clock resets,
asset changes and failed acoustic checks invalidate that calibration.
"""
import difflib
import json
from pathlib import Path
import re
import statistics
import shutil
import subprocess
import threading
import time

from live_media import Collector, playlist
from subtitle_catalog import discover, norm


def align(words, cues, timeline):
    tokens, firsts, asr, owners = [], {}, [], []
    for cue in cues:
        values = norm(cue['text']) if '♪' not in cue['text'] else []
        if values:
            firsts[len(tokens)] = cue
            tokens.extend(values)
    for word in words:
        for token in norm(word['word']):
            asr.append(token); owners.append(word)
    anchors = []
    for match in difflib.SequenceMatcher(None, tokens, asr, autojunk=False).get_matching_blocks():
        if match.size < 4:
            continue
        for index in range(match.a, match.a + match.size - 2):
            cue = firsts.get(index)
            if cue is None or len(norm(cue['text'])) < 3:
                continue
            word = owners[match.b + index - match.a]
            if word['probability'] < .55:
                continue
            onset = timeline + word['start']
            anchors.append(dict(cue=cue['index'], subtitleStart=cue['start'], asrStart=onset,
                                offset=cue['start'] - onset, words=match.size))
    if not anchors:
        return None, []
    cluster = max(([a for a in anchors if abs(a['offset'] - c['offset']) < .9] for c in anchors), key=len)
    if len({a['cue'] for a in cluster}) < 3 or max(a['asrStart'] for a in cluster) - min(a['asrStart'] for a in cluster) < 4:
        return None, anchors
    offset = statistics.median(a['offset'] for a in cluster)
    return offset, cluster


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
    def __init__(self, source, programme, root, model, ffmpeg, *, candidates=None, preferred_language='en', synchronous_analysis=False):
        self.root = Path(root); (self.root / 'analysis').mkdir(parents=True, exist_ok=True)
        self.collector = Collector(source, self.root, seconds=0)
        self.programme, self.model, self.ffmpeg = programme, model, ffmpeg
        self.lock = threading.RLock(); self.decisions = {}; self.candidates = candidates
        self.preferred_language = preferred_language
        self.state = 'ACQUIRING'; self.last_sequence = -1
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

    def run(self):
        try:
            if self.candidates is None:
                self.candidates = discover(self.programme['title'], self.programme['year'], self.root / 'subtitles',
                                           requested_language=self.preferred_language)
            self.candidates.sort(key=lambda c: (self.preferred_language not in c['tracks'], -len(c['tracks'])))
            self.event('subtitle_discovery', candidates=[dict(page=c['page'], languages=list(c['tracks'])) for c in self.candidates])
            if not self.candidates:
                self.event('no_existing_english_reference')
        except Exception as error:
            self.candidates = []; self.event('subtitle_discovery_error', errorType=type(error).__name__)
        run, last_analysis = [], -100.
        while not self.collector.stop.is_set() and not self.controller_stop.is_set():
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
                            self.state = 'ACQUIRING'; run = []
                            if self.pause is not None and self.returned is None:
                                self.returned = dict(start=row['timelineStart'], observedWall=row['observedWall'], sequence=row['sequence'])
                                self.event('movie_return_candidate', **self.returned)
                            if (known_asset and self.k is not None and self.last_pts_end is not None
                                    and abs(pts - self.last_pts_end) <= .16):
                                self.state = 'LOCKED'
                                self.resume = dict(timeline=row['timelineStart'], wall=time.time(), mode='verified_pts_continuity')
                                self.event('fast_clock_resume', **self.resume, sequence=row['sequence'],
                                           continuityErrorSeconds=pts - self.last_pts_end,
                                           observedRecoverySeconds=time.time() - row['observedWall'])
                        if self.state == 'LOCKED' and old_state == 'LOCKED' and self.last_pts_end is not None and abs(pts - self.last_pts_end) > .2:
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
                    offset = self.k + pts - row['timelineStart'] if self.state == 'LOCKED' and self.k is not None and pts is not None else None
                    if offset is not None and reference:
                        for language, cues in reference['tracks'].items():
                            emitted = [dict(index=c['index'], start=max(c['start'] - offset, row['timelineStart']),
                                            end=min(c['end'] - offset, row['timelineEnd']), text=c['text'])
                                       for c in cues if c['end'] - offset > row['timelineStart'] and c['start'] - offset < row['timelineEnd']]
                            if emitted:
                                tracks.append(dict(language=language, verified=True, cues=emitted))
                    decision = dict(start=row['timelineStart'], end=row['timelineEnd'], state=self.state,
                                    program=self.programme['movieId'], asset=row['asset'], tracks=tracks,
                                    sequence=row['sequence'], generatedWall=time.time(), pts=pts, offset=offset)
                    with self.lock:
                        self.decisions[row['sequence']] = decision
                        cutoff=row['timelineEnd']-7200
                        self.decisions={sequence:d for sequence,d in self.decisions.items() if d['end']>=cutoff}
                        with (self.root / 'decisions.jsonl').open('a') as file:
                            file.write(json.dumps(decision, ensure_ascii=False) + '\n')
                    (self.root / 'status.json').write_text(json.dumps(dict(state=self.state, lastSequence=self.last_sequence,
                        timeline=row['timelineEnd'], pause=self.pause, returned=self.returned, resume=self.resume,
                        holdout=list(self.holdout.values()), subtitleCandidates=len(self.candidates or []))))
            self.collector.stop.wait(.15)

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
                    candidate_k = found - pts + row['timelineStart']
                    if self.state != 'LOCKED':
                        self.reference = candidate; self.k = candidate_k; self.verified_asset = row['asset']; self.state = 'LOCKED'
                        self.calibration_cues = {a['cue'] for a in anchors}
                        if self.returned:
                            latest=self.collector.snapshot()[-1]
                            self.resume = dict(timeline=latest['timelineEnd'], wall=time.time(), mode='fresh_acoustic_lock')
                        self.event('acoustic_lock', timeline=row['timelineEnd'], wallSeconds=time.time()-started,
                                   subtitleMinusPts=self.k, anchors=anchors, afterReturn=bool(self.returned))
                    else:
                        offset=self.k+pts-row['timelineStart'];residuals=[a['offset']-offset for a in anchors]
                        self.event('acoustic_validation', timeline=row['timelineEnd'], anchors=anchors,
                                   residualSeconds=residuals,activeOffset=offset,afterReturn=bool(self.returned))
                        if abs(found-offset)>.9:
                            self.state='ACQUIRING';self.k=None;self.verified_asset=None;self.generation+=1;self.decisions.clear()
                            self.event('acoustic_calibration_invalidated', deviationSeconds=found-offset)
                        elif self.returned:
                            for anchor,residual in zip(anchors,residuals):
                                if anchor['asrStart']>=self.returned['start'] and anchor['cue'] not in self.calibration_cues:
                                    self.holdout[anchor['cue']]=dict(**anchor,errorSeconds=residual)
                break
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
