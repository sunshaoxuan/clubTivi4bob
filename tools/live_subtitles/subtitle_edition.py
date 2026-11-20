"""Verify one film edition while preserving each language's own cue boundaries."""
import bisect
import hashlib
import json
import re
import unicodedata


def _caption_text(text):
    return ' '.join(unicodedata.normalize('NFC', text).split())


def track_fingerprint(cues):
    """Identify parsed cues independently of SRT numbering, wrapping and BOM."""
    canonical = [(round(cue['start'] * 1000), round(cue['end'] * 1000),
                  _caption_text(cue['text'])) for cue in cues]
    return hashlib.sha256(json.dumps(canonical, ensure_ascii=False).encode()).hexdigest()


def transcript_fingerprint(cues):
    """Count one translation even when multiple files repeat it at new times."""
    transcript = ' '.join(_caption_text(cue['text']) for cue in cues)
    return hashlib.sha256(transcript.encode()).hexdigest()


def _edition_rows(metadata, english, alternatives):
    """Keep one canonical row and one sparse sibling for each distinct alternative."""
    primary = {language: next(iter(versions.values())) for language, versions in alternatives.items()}
    yield _edition(metadata, english, primary)
    for language, versions in alternatives.items():
        for translated in list(versions.values())[1:]:
            yield _edition(metadata, english, {language: translated})


def _edition(metadata, english, translations):
    tracks = {'en': english, **translations}
    return {
        **metadata,
        'tracks': {language: value[0] for language, value in tracks.items()},
        'provenance': {language: value[1] for language, value in tracks.items()},
    }


def pair_reference(metadata, english, english_facts, translations):
    """Pair each independently verified translation with its real English clock."""
    alternatives = {}
    for language, cues, facts in translations:
        evidence = timing_evidence(english, cues, english_facts, facts)
        if evidence:
            versions = alternatives.setdefault(language, {})
            versions.setdefault(track_fingerprint(cues), (cues, {**facts, 'timingEvidence': evidence}))
    reference = (english, {**english_facts, 'timingEvidence': {'method': 'identical_cue_grid'}})
    return list(_edition_rows(metadata, reference, alternatives))


def merge_editions(candidates):
    """Merge discovery rounds without replacing working tracks or acoustic references."""
    references = {}
    for candidate in candidates:
        english = candidate['tracks'].get('en')
        if not english:
            continue
        metadata = {name: value for name, value in candidate.items() if name not in ('tracks', 'provenance')}
        facts = candidate.get('provenance', {})
        key = (candidate['page'], track_fingerprint(english))
        metadata, reference, alternatives = references.setdefault(key, (metadata, (english, facts.get('en', {})), {}))
        if not candidate.get('cacheHit'):
            metadata.pop('cacheHit', None)
        for language, cues in candidate['tracks'].items():
            if language == 'en':
                continue
            translated = facts.get(language, {})
            if not timing_evidence(reference[0], cues, reference[1], translated):
                continue
            versions = alternatives.setdefault(language, {})
            versions.setdefault(track_fingerprint(cues), (cues, translated))
    return [edition for group in references.values() for edition in _edition_rows(*group)]


def chinese_script(cues, declared):
    if declared not in ('zh', 'zh-CN', 'zh-TW'):
        return declared
    text=''.join(c['text'] for c in cues)
    traditional='這們說來會時為麼學國裡對還讓過開關從實發現聽覺樣點無愛歡應該問題認識變覺經親長間東風書門車頭語讀寫聲數萬與'
    simplified='这们说来会时为么学国里对还让过开关从实发现听觉样点无爱欢应该问题认识变觉经亲长间东风书门车头语读写声数万与'
    a=sum(text.count(c) for c in set(traditional));b=sum(text.count(c) for c in set(simplified))
    if a+b>=20:
        if a/(a+b)>=.95:return 'zh-TW'
        if b/(a+b)>=.95:return 'zh-CN'
    return declared if declared in ('zh-CN','zh-TW') else None


def timing_evidence(english, translated, english_facts=None, translated_facts=None):
    grid=lambda cues:[(c['start'],c['end']) for c in cues]
    if grid(english)==grid(translated):return {'method':'identical_cue_grid'}
    a,b=english_facts or {},translated_facts or {}
    key=lambda label:re.findall(r'[a-z0-9]+',label.lower())
    imdb=a.get('imdbId')
    if (a.get('provider') not in ('SubDL','OpenSubtitles via Stremio') or
        b.get('provider')!=a.get('provider') or not isinstance(imdb,str) or
        not re.fullmatch(r'tt[0-9]{7,10}',imdb) or b.get('imdbId')!=imdb or
        not key(a.get('release','')) or key(a.get('release',''))!=key(b.get('release',''))):return None
    if len(english)<40 or len(translated)<40:return None
    if any(y['start']<x['start'] for cues in (english,translated) for x,y in zip(cues,cues[1:])):return None
    starts=[c['start'] for c in english];anchors=[];used=set()
    for cue in translated:
        i=bisect.bisect_left(starts,cue['start'])
        matches=[(j,english[j]) for j in range(max(0,i-2),min(len(english),i+3))
                 if abs(english[j]['start']-cue['start'])<=.2 and abs(english[j]['end']-cue['end'])<=.3]
        if len(matches)==1 and matches[0][0] not in used:
            used.add(matches[0][0]);anchors.append(cue['start'])
    begin,end=translated[0]['start'],translated[-1]['end'];span=end-begin
    if span<300 or len(anchors)<40 or len(anchors)/len(translated)<.07:return None
    bins={min(9,int((t-begin)/span*10)) for t in anchors}
    if len(bins)<8 or max(anchors)-min(anchors)<span*.8:return None
    merged=[]
    for cue in english:
        start,stop=cue['start']-.3,cue['end']+.3
        if merged and start<=merged[-1][1]:merged[-1][1]=max(stop,merged[-1][1])
        else:merged.append([start,stop])
    speech_starts=[x[0] for x in merged];overlap=0
    for cue in translated:
        middle=(cue['start']+cue['end'])/2;i=bisect.bisect_right(speech_starts,middle)-1
        overlap+=i>=0 and middle<=merged[i][1]
    coverage=overlap/len(translated)
    if coverage<.9:return None
    return dict(method='same_imdb_release_distributed_interval_anchors',anchorCount=len(anchors),
                anchorFraction=len(anchors)/len(translated),coveredTenths=len(bins),
                anchorSpanSeconds=max(anchors)-min(anchors),speechIntervalCoverage=coverage,
                maxStartDifferenceSeconds=.2,maxEndDifferenceSeconds=.3)
