"""Audit a completed native live test; never modify runtime/calibration input."""
import argparse
import json
from pathlib import Path
import statistics


def summarize(root):
    cycle=json.loads((root/'cycle-result.json').read_text())
    response=json.loads((root/'latest-session.json').read_text())
    native=json.loads((root/'native/result.json').read_text())
    samples=[json.loads(line) for line in (root/'native/observations.jsonl').read_text().splitlines()]
    origin=cycle['mediaClockOrigin'];lo=cycle['pause']['start']-origin;hi=cycle['returned']['start']-origin
    after=[s for s in samples if s['position']>=hi]
    normalize=lambda text:' '.join((text or '').split())
    measured=[]
    for h in cycle['holdout']:
        references=[(t['language'],c) for w in response['windows'] for t in w['tracks'] for c in t['cues'] if c['index']==h['cue']]
        at=h['asrStart']-origin
        # Associate with this utterance locally in time, avoiding an identical
        # short phrase elsewhere in the movie. Accommodate overlapping cues.
        matches=[(s,language) for s in after if abs(s['position']-at)<=2
                 for language,cue in references if normalize(cue['text']) and normalize(cue['text']) in normalize(s.get('text'))]
        if not matches:continue
        first,language=min(matches,key=lambda pair:pair[0]['elapsed'])
        measured.append(dict(cue=h['cue'],language=language,asrStart=at,
                             nativeCaptionPosition=first['position'],errorSeconds=first['position']-at))
    baseline=cycle['baseline']['wall']-cycle['testStartedWall']
    buffering=[s for s in samples if s['elapsed']>=baseline and s['buffering']]
    intervals=[]
    for s in buffering:
        if not intervals or s['elapsed']-intervals[-1][-1]['elapsed']>.2:intervals.append([])
        intervals[-1].append(s)
    intervals=[dict(startElapsed=x[0]['elapsed'],stopElapsed=x[-1]['elapsed'],
                    approximateSeconds=x[-1]['elapsed']-x[0]['elapsed']+.05,position=x[0]['position']) for x in intervals]
    warnings=[json.loads(line) for line in (root/'native/mpv.jsonl').read_text().splitlines()]
    corrupt=sum('corrupt' in x['text'].lower() for x in warnings)
    ad=[s for s in samples if lo<=s['position']<hi]
    first_caption=next((s for s in after if s.get('text')),None)
    available={t['language'] for w in response['windows'] if w['end']>hi for t in w['tracks']}
    selected='zh-CN' if 'zh-CN' in available else 'en'
    scheduled=[max(c['start'],hi) for w in response['windows'] if w['end']>hi
               for t in w['tracks'] if t['language']==selected for c in t['cues'] if c['end']>hi]
    first_scheduled=min(scheduled,default=None)
    errors=[abs(x['errorSeconds']) for x in measured]
    result={**cycle,'nativeHoldout':measured,'nativeMedianAbsoluteReferenceErrorSeconds':statistics.median(errors) if errors else None,
        'nativeMaximumAbsoluteReferenceErrorSeconds':max(errors,default=None),'bufferingIntervalsAfterVerifiedBaseline':intervals,
        'bufferingSamplesAfterVerifiedBaseline':len(buffering),'bufferingApproximateSecondsAfterVerifiedBaseline':sum(x['approximateSeconds'] for x in intervals),
        'corruptMediaWarnings':corrupt,'nativeErrors':native['errors'],'advertSamples':len(ad),
        'advertSamplesWithFilmCaption':sum(bool(s.get('text')) for s in ad),
        'nativeFirstCaptionDelaySeconds':first_caption['position']-hi if first_caption else None,
        'firstScheduledCaptionAfterReturn':first_scheduled,
        'nativeFirstCaptionLatenessSeconds':first_caption['position']-first_scheduled if first_caption and first_scheduled is not None else None,
        'referenceScope':'tiny.en word onset estimates; 50 ms native state sampling, backend decoded-position notifications; no manual lip-sync judgement'}
    result['overallAccepted']=bool(ad) and result['advertSamplesWithFilmCaption']==0 and len(measured)>=3 and max(errors,default=999)<=1 and not buffering and not corrupt and not native['errors']
    result.pop('unattendedCyclePassed',None)
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('capture',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
    result=summarize(a.capture);a.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:result[k] for k in ['overallAccepted','serverObservedRecoverySeconds','nativeFirstCaptionDelaySeconds','nativeMedianAbsoluteReferenceErrorSeconds','nativeMaximumAbsoluteReferenceErrorSeconds','advertSamplesWithFilmCaption','bufferingApproximateSecondsAfterVerifiedBaseline']}))
