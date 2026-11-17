"""Subtitle-only sessions. No media collector, audio download, or ASR model.

All observations are scoped to one viewer clock. The shared film cache contains
subtitle resources only. A new asset/epoch always needs fresh acoustic evidence.
"""
import json
import math
from pathlib import Path
import statistics
import sys
from urllib.parse import urlsplit
import threading
import time
import uuid
from live_engine import align, fit_clock_rate, clock_rate_confident
from subtitle_catalog import discover, LANGUAGES


def finite(value, low, high):
    if isinstance(value,bool) or not isinstance(value,(int,float)) or not math.isfinite(value) or not low<=value<=high:
        raise ValueError('invalid_clock_observation')
    return float(value)


class TextHub:
    client_only=True
    prewarm=False
    engine=None
    def __init__(self,root,cache,guide):
        self.root=Path(root);self.root.mkdir(parents=True,exist_ok=True)
        self.traffic=dict(receivedJsonBytes=0,sentJsonBytes=0,outboundRequests=0,outboundMediaRequests=0,outboundHosts={})
        def audit(event,args):
            if event=='urllib.Request':
                uri=urlsplit(args[0]);host=uri.hostname or ''
                self.traffic['outboundRequests']+=1
                self.traffic['outboundHosts'][host]=self.traffic['outboundHosts'].get(host,0)+1
                if uri.path.endswith(('.m3u8','.ts','.mp4','.m4s')):self.traffic['outboundMediaRequests']+=1
        sys.addaudithook(audit)
        self.cache,self.guide=cache,guide
        self.lock=threading.RLock();self.sessions={};self.candidates=None;self.discovery_error=False
        self.source,self.programme=self.guide();self.last_guide_success=time.time();self.gap=False
        self.discovery_generation=0;self.last_discovery=0;self.discovery_busy=False
        self.fetch_subtitles()
        threading.Thread(target=self.maintain,daemon=True).start()
    def event(self,kind,**facts):
        with (self.root/'client-clock-events.jsonl').open('a') as f:
            f.write(json.dumps(dict(event=kind,wall=time.time(),**facts))+'\n')
    def fetch_subtitles(self):
        if self.discovery_busy:return
        self.discovery_busy=True;generation=self.discovery_generation;programme=dict(self.programme)
        def work():
            try:
                candidates=self.cache.get_or_discover(programme,self.root/'discovery'/uuid.uuid4().hex,discover,requested_language='en')
                with self.lock:
                    if generation==self.discovery_generation:self.candidates=candidates;self.discovery_error=False
                self.event('subtitle_resources_ready',programmeKey=programme['key'],candidates=len(candidates))
            except Exception as e:
                with self.lock:
                    if generation==self.discovery_generation:self.discovery_error=True
                self.event('subtitle_discovery_error',errorType=type(e).__name__)
            finally:self.discovery_busy=False;self.last_discovery=time.monotonic()
        threading.Thread(target=work,daemon=True).start()
    def valid_context(self,source,programme):
        return source==self.source and not self.gap and time.time()<self.programme['stopUtc'] and time.time()-self.last_guide_success<=120 and (programme is None or isinstance(programme,dict) and programme.get('key')==self.programme['key'])
    def create(self,source,context,language,features=()):
        with self.lock:
            if 'clientClockV1' not in features or not self.valid_context(source,context) or language not in LANGUAGES:raise ValueError('client_clock_required')
            if len(self.sessions)>=32:raise RuntimeError('pilot_capacity')
            token=uuid.uuid4().hex
            self.sessions[token]=dict(source=source,lastAccess=time.time(),language=language,epoch=None,asset=None,reference=None,rate=1.,intercept=None,points={},windows=[],lastObservation=-1,programmeKey=self.programme['key'],ad=False,lastWindow=None)
            return token
    def ingest(self,token,data):
        with self.lock:
            session=self.sessions[token]
            if not self.valid_context(data.get('source'),data.get('programme')) or data.get('programmeKey')!=self.programme['key']:raise ValueError('stale_programme')
            epoch=data.get('epoch');asset=data.get('asset');ad=data.get('ad')
            if not isinstance(epoch,int) or isinstance(epoch,bool) or not 0<=epoch<1e9 or not isinstance(asset,str) or not 1<=len(asset)<=512 or not isinstance(ad,bool):raise ValueError('invalid_epoch')
            start=finite(data.get('start'),0,86400*14);end=finite(data.get('end'),start,start+40)
            serial=data.get('serial')
            if not isinstance(serial,int) or isinstance(serial,bool) or serial<=session['lastObservation']:raise ValueError('replayed_observation')
            raw=data.get('words',[])
            if not isinstance(raw,list) or len(raw)>512:raise ValueError('word_limit')
            words=[]
            for w in raw:
                if not isinstance(w,dict) or not isinstance(w.get('word'),str) or not 0<len(w['word'])<=200:raise ValueError('invalid_word')
                a=finite(w.get('start'),0,end-start+.5);b=finite(w.get('end'),a,end-start+.5)
                words.append(dict(word=w['word'],start=a,end=b,probability=finite(w.get('probability'),0,1)))
            previous=session['lastWindow']
            if previous and epoch<session['epoch']:raise ValueError('stale_epoch')
            changed=(session['epoch']!=epoch or session['asset']!=asset or session['programmeKey']!=self.programme['key'])
            if changed:
                if session['programmeKey']!=self.programme['key']:
                    session.pop('priorReference',None);session.pop('priorRate',None)
                elif session['reference'] is not None:
                    session['priorReference']=session['reference'];session['priorRate']=session['rate']
                session.update(epoch=epoch,asset=asset,reference=None,intercept=None,rate=1.,points={},programmeKey=self.programme['key'])
            session.update(lastObservation=serial,lastAccess=time.time(),lastWindow=dict(start=start,end=end),ad=ad)
            if ad:
                session['windows']=[w for w in session['windows'] if w['end']<=start]
                session['reference']=None;session['intercept']=None;session['points']={}
                session['windows'].append(dict(start=start,end=end,state='SUSPENDED',program=self.programme['movieId'],asset=asset,tracks=[]))
                self.event('advert_observation',session=token,epoch=epoch,start=start,end=end)
                return
            if not words:return
            prior=session.get('priorReference')
            trial=([session['reference']] if session['reference'] else ([prior] if prior else [])+[c for c in self.candidates or [] if c is not prior])
            selected=None
            for candidate in trial:
                offset,anchors=align(words,candidate['tracks']['en'],start)
                if offset is None and candidate is prior:
                    # A previously matched edition still needs fresh multi-cue
                    # dialogue. This shortens ad recovery without reusing offset.
                    cluster=max(([a for a in anchors if abs(a['offset']-c['offset'])<.6] for c in anchors),key=len,default=[])
                    if (len({a['cue'] for a in cluster})>=2 and
                        max(a['asrStart'] for a in cluster)-min(a['asrStart'] for a in cluster)>=2 and
                        all(a['words']>=8 for a in cluster)):
                        offset=statistics.median(a['offset'] for a in cluster);anchors=cluster
                if offset is not None:selected=(candidate,anchors);break
            if selected is None:
                if len(words)>=10:
                    session['reference']=None;session['intercept']=None;session['windows']=[w for w in session['windows'] if w['end']<=start]
                    self.event('unmatched_speech',session=token,start=start,end=end,words=len(words))
                return
            candidate,anchors=selected
            if session.get('candidateKey')!=candidate['page']:
                session.update(candidateKey=candidate['page'],points={},intercept=None,rate=session.get('priorRate',1.) if candidate is prior else 1.)
            for a in anchors:session['points'][a['cue']]=dict(cue=a['cue'],sourcePts=a['asrStart'],subtitleStart=a['subtitleStart'])
            points=list(session['points'].values())[-128:];proposal=fit_clock_rate(points)
            rate=proposal['rate'] if proposal else session['rate']
            intercept=proposal['intercept'] if proposal else statistics.median(a['subtitleStart']-rate*a['asrStart'] for a in anchors)
            prior=session['intercept'];residuals=[(a['subtitleStart']-(session['rate']*a['asrStart']+prior))/session['rate'] for a in anchors] if prior is not None else []
            session.update(reference=candidate,intercept=intercept,rate=rate)
            # Refresh only observed movie windows; ad intervals remain excluded.
            movie_end=end+12
            tracks=[]
            for language,cues in candidate['tracks'].items():
                emitted=[dict(index=c['index'],start=(c['start']-intercept)/rate,end=(c['end']-intercept)/rate,text=c['text']) for c in cues if c['end']>=rate*start+intercept and c['start']<=rate*movie_end+intercept]
                if emitted:tracks.append(dict(language=language,verified=True,cues=emitted))
            session['windows']=[w for w in session['windows'] if w['end']<=start and w['end']>end-180]
            session['windows'].append(dict(start=start,end=movie_end,state='LOCKED',program=self.programme['movieId'],asset=asset,tracks=tracks))
            self.event('client_acoustic_lock',session=token,epoch=epoch,start=start,end=end,rate=rate,intercept=intercept,anchors=anchors,residualSeconds=residuals,clockRateVerified=clock_rate_confident(points,rate,intercept))
    def response(self,token,position=None):
        with self.lock:
            s=self.sessions[token];s['lastAccess']=time.time();valid=self.valid_context(s['source'],None)
            phase='programme_unavailable' if not valid else 'service_unavailable' if self.discovery_error else 'searching' if self.candidates is None else 'unavailable' if not self.candidates else 'matched' if s['reference'] else 'synchronizing'
            return dict(session=token,source=s['source'],clientClock=True,playbackReady=False,playbackUrl=s['source'],programmeKey=self.programme['key'],programme=self.programme,mediaClockOrigin=0,subtitleStatus=dict(phase=phase,availableLanguages=sorted(s['reference']['tracks']) if s['reference'] else [],cacheHit=bool(self.candidates and all(c.get('cacheHit') for c in self.candidates))),windows=s['windows'] if valid and s['programmeKey']==self.programme['key'] else [])
    def maintain(self):
        next_guide=time.monotonic()+25
        while True:
            time.sleep(1)
            with self.lock:
                self.sessions={t:s for t,s in self.sessions.items() if time.time()-s['lastAccess']<=180}
            if time.monotonic()<next_guide:continue
            next_guide=time.monotonic()+25
            try:
                source,programme=self.guide()
                with self.lock:
                    changed=programme['key']!=self.programme['key'];self.source,self.programme=source,programme
                    self.last_guide_success=time.time();self.gap=False
                    if changed:self.discovery_generation+=1;self.candidates=None
                    if changed or self.discovery_error and time.monotonic()-self.last_discovery>60:self.fetch_subtitles()
            except Exception:self.gap=True
