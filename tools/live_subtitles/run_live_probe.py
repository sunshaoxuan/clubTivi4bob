"""Run one unattended native live-ad cycle; never alter calibration decisions."""
import argparse
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import threading
import time
from urllib.request import Request, urlopen

from service import current_guide

REMOTE_STATUS = r'''
from pathlib import Path
import json
root=Path('/var/lib/bobtv/live-subtitles');paths=list(root.rglob('status.json'))
if not paths:print('{}');raise SystemExit()
p=max(paths,key=lambda p:p.stat().st_mtime);status=json.loads(p.read_text())
events=p.parent/'controller-events.jsonl'
print(json.dumps({'path':str(p),'status':status,'events':[json.loads(line) for line in events.read_text().splitlines()][-12:]}))
'''


def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--app',required=True)
    p.add_argument('--key',required=True);p.add_argument('--seconds',type=int,default=6000);a=p.parse_args()
    root=a.output.resolve();root.mkdir(parents=True,exist_ok=True);native=root/'native';native.mkdir(exist_ok=True)
    context=root/'context.json';stop=threading.Event();source,programme=current_guide()
    def update():
        while not stop.is_set():
            try:
                route,programme=current_guide();temp=context.with_suffix('.tmp')
                temp.write_text(json.dumps(dict(source=route,programme=programme)));os.replace(temp,context)
            except Exception:
                pass
            stop.wait(15)
    context.write_text(json.dumps(dict(source=source,programme=programme)))
    threading.Thread(target=update,daemon=True).start()
    env=dict(os.environ,BOBTV_SUBTITLE_PROBE_OUTPUT=str(native),BOBTV_SUBTITLE_PROBE_SOURCE=source,
             BOBTV_SUBTITLE_PROBE_CONTEXT=str(context),BOBTV_SUBTITLE_PROBE_SECONDS=str(a.seconds))
    started=time.time();frozen=None;last_state=None;last_status={};caption_session=None
    log=(root/'native.log').open('w');process=subprocess.Popen([a.app],env=env,stdout=log,stderr=subprocess.STDOUT)
    (root/'run.json').write_text(json.dumps(dict(startedWall=started,pid=process.pid,source=source,
        commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),scope='real current live source, no archive decisions imported'),indent=2))
    passed=False
    try:
        while process.poll() is None and time.time()-started<a.seconds:
            time.sleep(10)
            result=subprocess.run(['ssh','-i',a.key,'-o','BatchMode=yes','-o','ConnectTimeout=5','root@ccnode.briconbric.com','python3','-'],
                                  input=REMOTE_STATUS,text=True,capture_output=True,timeout=15)
            if result.returncode:
                continue
            try:server=json.loads(result.stdout)
            except ValueError:continue
            if not server:continue
            last_status=server;status=server['status'];state=status['state']
            with (root/'server-observations.jsonl').open('a') as f:f.write(json.dumps(dict(observedWall=time.time(),**server))+'\n')
            resolved=native/'resolved-media.json'
            if resolved.exists() and caption_session is None:
                path=json.loads(resolved.read_text()).get('mediaPath','');match=re.search(r'/media/([a-f0-9]{32})/index.m3u8',path)
                if not match:raise RuntimeError('native_did_not_use_live_subtitle_service')
                caption_session=match[1]
            if caption_session:
                request=Request('https://bobtv.briconbric.com/api/v1/subtitles/sessions/'+caption_session,headers={'User-Agent':'BobTV-EPG-Validator/1.0'})
                response=json.load(urlopen(request,timeout=10));(root/'latest-session.json').write_text(json.dumps(response,ensure_ascii=False))
            else:continue
            observations=native/'observations.jsonl'
            samples=[json.loads(line) for line in observations.read_text().splitlines() if line.endswith('}')] if observations.exists() else []
            if state!=last_state:
                print(json.dumps(dict(state=state,timeline=status['timeline'],holdout=len(status['holdout']),wall=time.time())),flush=True);last_state=state
            if frozen is None and state=='LOCKED' and any(s.get('text') for s in samples):
                frozen=dict(wall=time.time(),position=samples[-1]['position'],serverTimeline=status['timeline'],mediaClockOrigin=response['mediaClockOrigin'])
                (root/'frozen.json').write_text(json.dumps(frozen,indent=2));print('baseline verified; waiting for a full real insertion',flush=True)
            pause,returned,resume=status['pause'],status['returned'],status['resume']
            if not (frozen and pause and returned and resume and pause['observedWall']>frozen['wall'] and len(status['holdout'])>=3):
                continue
            origin=response['mediaClockOrigin'];lo=pause['start']-origin;hi=returned['start']-origin
            # New acoustic holdouts can be minutes after the return. Wait
            # until those actual cues have passed through the native player.
            holdout=status['holdout'][:3]
            if not samples or samples[-1]['position']<max(hi+60,max(h['asrStart'] for h in holdout)-origin+3):continue
            ad=[s for s in samples if lo<=s['position']<hi]
            after=[s for s in samples if s['position']>=hi and s.get('text')]
            if not ad or not after:continue
            errors=[abs(h['errorSeconds']) for h in holdout]
            native_errors=[]
            for h in holdout:
                cues=[c for w in response['windows'] for t in w['tracks'] if t['language']=='en'
                      for c in t['cues'] if c['index']==h['cue']]
                texts={' '.join(c['text'].split()) for c in cues}
                matched=[s for s in after if ' '.join((s.get('text') or '').split()) in texts]
                if matched:
                    native_errors.append(dict(cue=h['cue'],position=matched[0]['position'],
                        asrStart=h['asrStart']-origin,errorSeconds=matched[0]['position']-(h['asrStart']-origin)))
            result=dict(realLive=True,scope='server live ASR and native Flutter client; sampled caption state, not OCR',
                testStartedWall=started,baseline=frozen,pause=pause,returned=returned,resume=resume,
                mediaClockOrigin=origin,adMediaSeconds=hi-lo,advertSamples=len(ad),
                advertSamplesWithFilmCaption=sum(bool(s.get('text')) for s in ad),
                serverObservedRecoverySeconds=resume['wall']-returned['observedWall'],
                serverMediaRecoverySeconds=resume['timeline']-returned['start'],
                nativeFirstCaptionDelaySeconds=after[0]['position']-hi,
                holdoutCueCount=len(holdout),holdout=holdout,
                nativeHoldout=native_errors,
                nativeMedianAbsoluteReferenceErrorSeconds=statistics.median(abs(x['errorSeconds']) for x in native_errors) if native_errors else None,
                nativeMaximumAbsoluteReferenceErrorSeconds=max((abs(x['errorSeconds']) for x in native_errors),default=None),
                medianAbsoluteAsrReferenceErrorSeconds=statistics.median(errors),maximumAbsoluteAsrReferenceErrorSeconds=max(errors),
                layouts=sorted({s['layout'] for s in samples}),
                bufferingSamplesAfterStartup=sum(s['buffering'] for s in samples if s['elapsed']>10))
            result['captionCyclePassed']=result['advertSamplesWithFilmCaption']==0 and len(native_errors)>=3
            passed=result['captionCyclePassed'] and result['bufferingSamplesAfterStartup']==0
            result['unattendedCyclePassed']=passed;(root/'cycle-result.json').write_text(json.dumps(result,indent=2))
            (native/'STOP').write_text('measured live cycle complete');print(json.dumps(result),flush=True);break
        if process.poll() is None:
            (native/'STOP').write_text('runner deadline or completion')
            process.wait(timeout=30)
    finally:
        stop.set();log.close()
        if not passed:(root/'incomplete.json').write_text(json.dumps(dict(lastStatus=last_status,reason='no complete verified cycle',frozen=frozen),indent=2))
    raise SystemExit(0 if passed else 2)


if __name__=='__main__':main()
