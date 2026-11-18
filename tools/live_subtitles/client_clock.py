"""Subtitle-only sessions. No media collector, audio download, or ASR model.

All observations are scoped to one viewer clock. The shared film cache contains
subtitle resources only. A new asset/epoch always needs fresh acoustic evidence.
"""
import hashlib
import json
import math
import re
from pathlib import Path
import statistics
import sys
from urllib.parse import urlsplit
import threading
import time
import uuid
from live_engine import align, fit_clock_rate, clock_rate_confident
from subtitle_catalog import discover, LANGUAGES
from service import reviewed_pilot_source
from transport_clock import clock as source_clock, project as project_clock


def finite(value, low, high):
    if isinstance(value,bool) or not isinstance(value,(int,float)) or not math.isfinite(value) or not low<=value<=high:
        raise ValueError('invalid_clock_observation')
    return float(value)


class TextHub:
    client_only=True
    prewarm=False
    engine=None
    def __init__(self,root,cache,guide,*,traffic=None,source_validator=None,auto_maintain=True):
        self.root=Path(root);self.root.mkdir(parents=True,exist_ok=True)
        self.traffic=traffic if traffic is not None else dict(receivedJsonBytes=0,sentJsonBytes=0,outboundRequests=0,outboundMediaRequests=0,outboundHosts={})
        def audit(event,args):
            if event=='urllib.Request':
                uri=urlsplit(args[0]);host=uri.hostname or ''
                self.traffic['outboundRequests']+=1
                self.traffic['outboundHosts'][host]=self.traffic['outboundHosts'].get(host,0)+1
                if uri.path.endswith(('.m3u8','.ts','.mp4','.m4s')):self.traffic['outboundMediaRequests']+=1
        if traffic is None:sys.addaudithook(audit)
        self.cache,self.guide=cache,guide
        self.source_validator=source_validator;self.stop_event=threading.Event()
        self.requested_languages=set()
        self.lock=threading.RLock();self.sessions={};self.candidates=None;self.discovery_error=False
        self.source,self.programme=self.guide();self.last_guide_success=time.time();self.gap=False
        self.discovery_generation=0;self.last_discovery=0;self.discovery_busy=False
        self.fetch_subtitles()
        self.next_guide=time.monotonic()+25
        if auto_maintain:threading.Thread(target=self.maintain,daemon=True).start()
    def event(self,kind,**facts):
        with (self.root/'client-clock-events.jsonl').open('a') as f:
            f.write(json.dumps(dict(event=kind,wall=time.time(),**facts))+'\n')
    def fetch_subtitles(self,language='en'):
        with self.lock:
            self.requested_languages.add(language)
            if self.discovery_busy:return
            self.discovery_busy=True
        def work():
            while True:
                with self.lock:
                    if not self.requested_languages:
                        self.discovery_busy=False;self.last_discovery=time.monotonic();return
                    language=self.requested_languages.pop();generation=self.discovery_generation;programme=dict(self.programme)
                try:
                    candidates=self.cache.get_or_discover(programme,self.root/'discovery'/uuid.uuid4().hex,discover,requested_language=language) if programme.get('searchable',True) else []
                    with self.lock:
                        if generation==self.discovery_generation:self.candidates=candidates;self.discovery_error=False
                    self.event('subtitle_resources_ready',programmeKey=programme['key'],language=language,candidates=len(candidates))
                except Exception as e:
                    with self.lock:
                        if generation==self.discovery_generation:self.discovery_error=not bool(self.candidates)
                    self.event('subtitle_discovery_error',language=language,errorType=type(e).__name__)
        threading.Thread(target=work,daemon=True).start()
    def valid_context(self,source,programme):
        return (self.source_validator(source) if getattr(self,'source_validator',None) else source==self.source or reviewed_pilot_source(source) and reviewed_pilot_source(self.source)) and not self.gap and time.time()<self.programme['stopUtc'] and time.time()-self.last_guide_success<=120 and (programme is None or isinstance(programme,dict) and programme.get('key')==self.programme['key'])
    def create(self,source,context,language,features=()):
        with self.lock:
            if 'clientClockV1' not in features or not self.valid_context(source,context) or language not in LANGUAGES:raise ValueError('client_clock_required')
            if len(self.sessions)>=32:raise RuntimeError('pilot_capacity')
            token=uuid.uuid4().hex
            self.sessions[token]=dict(source=source,lastAccess=time.time(),language=language,epoch=None,asset=None,reference=None,rate=1.,intercept=None,points={},windows=[],lastObservation=-1,programmeKey=self.programme['key'],ad=False,lastWindow=None,unmatchedWindows=0,exhausted=False,pendingAnchors={})
            if hasattr(self,'requested_languages'):self.fetch_subtitles(language)
            return token
    def clock_window(self,session,candidate,start,end,rate,intercept):
        tracks=[]
        for language,cues in candidate['tracks'].items():
            emitted=[dict(index=c['index'],start=(c['start']-intercept)/rate,end=(c['end']-intercept)/rate,text=c['text']) for c in cues if c['end']>=rate*start+intercept and c['start']<=rate*end+intercept]
            if emitted:tracks.append(dict(language=language,verified=True,cues=emitted))
        session['windows']=[w for w in session['windows'] if w['end']<=start and w['end']>end-180]
        session['windows'].append(dict(start=start,end=end,state='LOCKED',program=self.programme['movieId'],asset=session['asset'],tracks=tracks))

    def project_transport(self,session,clock,*,start,end,position,epoch,asset,token):
        model=session.get('sourceModel')
        evidence=project_clock(model,clock,asset=asset,programme=self.programme['key'],epoch=epoch,start=start,position=position,ad_start=session.get('adStart'),ad_clock_start=session.get('adClockStart'),now=time.time())
        if evidence is None:
            if model and epoch!=model['epoch'] and session.get('adStart') is not None and session.get('transportRejectedEpoch')!=epoch:
                session['transportRejectedEpoch']=epoch
                self.event('client_transport_clock_rejected',session=token,epoch=epoch,clockAvailable=clock is not None,adClockStart=session.get('adClockStart'),clockReturn=clock.get('updatedAt') if clock else None,adStart=session.get('adStart'),returnStart=start,modelAgeSeconds=round(time.time()-model['verifiedAt'],3))
            if session.get('transportAt') is not None:
                session.pop('transportAt',None)
                session['windows']=[w for w in session['windows'] if w['end']<=position]
            return False
        candidate=model['reference'];rate=evidence['rate'];intercept=evidence['intercept']
        if evidence['resumed']:
            # SSAI can edit content while preserving plausible AV timestamps.
            # A transport proposal is a search hint, never permission to show
            # movie captions until fresh dialogue confirms the content clock.
            if session.get('pendingTransport',{}).get('epoch')!=epoch:
                self.event('client_transport_clock_pending',session=token,epoch=epoch,start=start,end=end,rate=rate,intercept=intercept,sourceMovieAdvanceSeconds=evidence['sourceMovieAdvanceSeconds'])
            session['pendingTransport']=dict(epoch=epoch,**evidence)
            session.update(priorReference=candidate,priorRate=rate,priorRateVerified=True,reference=None,intercept=None)
            session.pop('transportAt',None)
            session['windows']=[w for w in session['windows'] if w['end']<=start]
            return False
        session.update(reference=candidate,lastMatchedReference=candidate,rate=rate,rateVerified=True,intercept=intercept,unmatchedWindows=0,exhausted=False,transportAt=time.time())
        session['acceptedClock']=dict(page=candidate['page'],rate=rate,intercept=intercept)
        self.clock_window(session,candidate,evidence['start'],max(end+12,position+12),rate,intercept)
        return True

    def ingest(self,token,data):
        with self.lock:
            session=self.sessions[token]
            if not self.valid_context(data.get('source'),data.get('programme')) or data.get('programmeKey')!=self.programme['key']:raise ValueError('stale_programme')
            epoch=data.get('epoch');asset=data.get('asset');ad=data.get('ad')
            if not isinstance(epoch,int) or isinstance(epoch,bool) or not 0<=epoch<1e9 or not isinstance(asset,str) or not 1<=len(asset)<=512 or not isinstance(ad,bool):raise ValueError('invalid_epoch')
            start=finite(data.get('start'),0,86400*14);end=finite(data.get('end'),start,start+40)
            position=finite(data.get('position',end),0,end+120)
            clock=source_clock(data.get('sourceClock'),end)
            serial=data.get('serial')
            seen=session.setdefault('seenObservations',set())
            if not isinstance(serial,int) or isinstance(serial,bool) or serial<1 or serial in seen or serial<=session['lastObservation']-128:raise ValueError('replayed_observation')
            raw=data.get('words',[])
            if not isinstance(raw,list) or len(raw)>512:raise ValueError('word_limit')
            words=[]
            for w in raw:
                if not isinstance(w,dict) or not isinstance(w.get('word'),str) or not 0<len(w['word'])<=200:raise ValueError('invalid_word')
                a=finite(w.get('start'),0,end-start+.5);b=finite(w.get('end'),a,end-start+.5)
                words.append(dict(word=w['word'],start=a,end=b,probability=finite(w.get('probability'),0,1)))
            language=data.get('language',session['language'])
            if language not in LANGUAGES:raise ValueError('unsupported_language')
            self.set_language(token,language)
            previous=session['lastWindow']
            if previous and epoch<session['epoch']:raise ValueError('stale_epoch')
            delayed=serial<session['lastObservation']
            if delayed and (epoch!=session['epoch'] or asset!=session['asset'] or ad!=session['ad']):raise ValueError('stale_epoch')
            highest=max(serial,session['lastObservation'])
            seen.add(serial);seen.intersection_update(s for s in seen if s>highest-128)
            # Heartbeats can overtake a larger speech request on another HTTP
            # connection. Keep unique speech in this asset epoch, without
            # rewinding the viewer's latest transport observation.
            if delayed and not words:return
            changed=(session['epoch']!=epoch or session['asset']!=asset or session['programmeKey']!=self.programme['key'])
            if changed:
                session.pop('pendingTransport',None)
                session.pop('clockJump',None);session.pop('acceptedClock',None);session.pop('editionSwitch',None)
                if session['programmeKey']!=self.programme['key']:
                    session.pop('priorReference',None);session.pop('priorRate',None);session.pop('priorAsset',None);session.pop('lastMatchedReference',None)
                    session.pop('sourceModel',None);session.pop('transportAt',None);session.pop('adStart',None);session.pop('adClockStart',None)
                elif session.get('reference') is not None or (session.get('lastMatchedReference') is not None and (ad or session.get('rateVerified',False))):
                    session['priorReference']=session['reference'] or session['lastMatchedReference'];session['priorRate']=session['rate'];session['priorRateVerified']=session.get('rateVerified',False);session['priorAsset']=session['asset']
                if not ad and session.get('priorAsset')!=asset:session['priorRateVerified']=False
                model=session.get('sourceModel')
                if not ad and model and model['asset']==asset and model['programme']==self.programme['key']:
                    session['priorReference']=model['reference'];session['priorRate']=model['rate'];session['priorRateVerified']=True
                session.update(epoch=epoch,asset=asset,reference=None,intercept=None,rate=session.get('priorRate',1.),points={},rateVerified=False,programmeKey=self.programme['key'],unmatchedWindows=0,exhausted=False,pendingAnchors={})
            window=previous if delayed and previous and previous['end']>end else dict(start=start,end=end)
            session.update(lastObservation=highest,lastAccess=time.time(),lastWindow=window,ad=ad)
            if ad:
                if changed or 'adStart' not in session:
                    session['adStart']=start
                    session['adClockStart']=clock['updatedAt'] if clock and abs(clock['updatedAt']-start)<=12 else None
                session.pop('transportAt',None)
                session['windows']=[w for w in session['windows'] if w['end']<=start]
                session['reference']=None;session['intercept']=None;session['points']={}
                session['windows'].append(dict(start=start,end=end,state='SUSPENDED',program=self.programme['movieId'],asset=asset,tracks=[]))
                self.event('advert_observation',session=token,epoch=epoch,start=start,end=end)
                return
            projected=self.project_transport(session,clock,start=start,end=end,position=position,epoch=epoch,asset=asset,token=token)
            if not words:return
            prior=session.get('priorReference')
            known=session['reference'] or session.get('lastMatchedReference') or prior
            preferred=[c for c in self.candidates or [] if session['language'] in c['tracks']]
            # Prove the requested language's edition first. An already matched
            # fallback remains available until a preferred edition is verified.
            trial=([known] if known and session['language'] in known['tracks'] else preferred[:])
            if known is not None and known not in trial:trial.append(known)
            if known is None or session['unmatchedWindows']>=3:
                trial += [c for c in self.candidates or [] if c not in trial]
            selected=None
            for candidate in trial:
                candidate_rate=session['rate'] if session.get('candidateKey')==candidate['page'] else session.get('priorRate',1.) if candidate is prior else 1.
                offset,anchors=align(words,candidate['tracks']['en'],start,rate=candidate_rate)
                # Accumulate distinct, exact cue-onset matches across overlapping
                # windows. Epoch/asset changes clear this evidence completely.
                fresh_ids={a['cue'] for a in anchors}
                pending=session.setdefault('pendingAnchors',{}).setdefault(candidate['page'],{})
                for anchor in anchors:
                    pending[anchor['cue']]=anchor
                pending={key:a for key,a in pending.items() if end-120 <= a['asrStart'] <= end}
                session['pendingAnchors'][candidate['page']]=pending
                accumulated=list(pending.values())
                known_rate=(session.get('candidateKey')==candidate['page'] and session.get('rateVerified',False) or candidate is prior and session.get('priorRateVerified',False))
                rates=[candidate_rate] if known_rate else [1.,24/25,(24000/1001)/25,25/24,25/(24000/1001)]
                identity=candidate.get('provenance',{}).get('en',{}).get('imdbId')
                bound=bool(isinstance(identity,str) and re.fullmatch(r'tt[0-9]{7,10}',identity) and
                           (self.programme.get('imdbId') is None or self.programme['imdbId']==identity))
                hypotheses=[]
                for trial_rate in rates:
                    projected=[{**a,'offset':a['subtitleStart']-trial_rate*a['asrStart']} for a in accumulated]
                    clusters=[[a for a in projected if abs(a['offset']-c['offset'])<.6] for c in projected]
                    cluster=max((group for group in clusters if any(a['cue'] in fresh_ids for a in group)),key=len,default=[])
                    if not cluster:continue
                    count=len({a['cue'] for a in cluster})
                    span=max(a['asrStart'] for a in cluster)-min(a['asrStart'] for a in cluster)
                    long_pair=(candidate is prior or bound) and count>=2 and span>=2 and all(a['words']>=8 for a in cluster)
                    warm_pair=(candidate is prior and session.get('priorRateVerified',False) and
                               count>=2 and span>=2 and all(a['words']>=4 for a in cluster))
                    if not ((count>=3 and span>=4) or long_pair or warm_pair):continue
                    intercept=statistics.median(a['offset'] for a in cluster)
                    spread=statistics.median(abs(a['offset']-intercept) for a in cluster)
                    hypotheses.append((count,-spread,trial_rate,intercept,cluster))
                if hypotheses:
                    _,_,candidate_rate,offset,anchors=max(hypotheses,key=lambda h:(h[0],h[1]))
                if offset is not None:selected=(candidate,anchors,candidate_rate);break
            if selected is None:
                if len(words)>=10:
                    session['unmatchedWindows']+=1;session['exhausted']=not projected and session['unmatchedWindows']>=3
                    if not projected:
                        session['reference']=None;session['intercept']=None;session['windows']=[w for w in session['windows'] if w['end']<=start]
                    self.event('unmatched_speech',session=token,start=start,end=end,words=len(words))
                return
            candidate,anchors,selected_rate=selected
            if session.get('adStart') is not None:
                exact=[a for a in anchors if not a.get('fuzzyPrefix') and a['words']>=4]
                if len({a['cue'] for a in exact})<2 or max(a['asrStart'] for a in exact)-min(a['asrStart'] for a in exact)<2:
                    return
                anchors=exact
            accepted=session.get('acceptedClock',{})
            if accepted and accepted.get('page')!=candidate['page']:
                pending=session.setdefault('editionSwitch',{})
                if pending.get('page')!=candidate['page']:
                    pending=dict(page=candidate['page'],windows=[]);session['editionSwitch']=pending
                windows=pending['windows']
                windows[:]=[w for w in windows if end-w['end']<=30]
                windows.append(dict(end=end,cues=[a['cue'] for a in anchors]))
                if not (len({w['end'] for w in windows})>=2 and
                        max(w['end'] for w in windows)-min(w['end'] for w in windows)>=6 and
                        len({cue for w in windows for cue in w['cues']})>=4):
                    session.pop('sourceModel',None);session.pop('transportAt',None)
                    session['reference']=None
                    session['windows']=[w for w in session['windows'] if w['end']<=start]
                    self.event('subtitle_edition_pending',session=token,epoch=epoch,start=start,end=end)
                    return
                self.event('subtitle_edition_changed',session=token,epoch=epoch,start=start,end=end,
                           referenceId=hashlib.sha256(candidate['page'].encode()).hexdigest())
            session.pop('editionSwitch',None)
            if session.get('candidateKey')!=candidate['page']:
                session.update(candidateKey=candidate['page'],points={},intercept=None,rate=selected_rate)
            old_points=dict(session['points'])
            for a in anchors:session['points'][a['cue']]=dict(cue=a['cue'],sourcePts=a['asrStart'],subtitleStart=a['subtitleStart'])
            points=list(session['points'].values())[-128:];proposal=fit_clock_rate(points,session['rate'])
            rate=proposal['rate'] if proposal else session['rate'] if session.get('rateVerified',False) else selected_rate
            intercept=proposal['intercept'] if proposal else statistics.median(a['subtitleStart']-rate*a['asrStart'] for a in anchors)
            baseline=session.get('acceptedClock',{})
            baseline=baseline if baseline.get('page')==candidate['page'] else {}
            prior=baseline.get('intercept',session['intercept']);old_rate=baseline.get('rate',session['rate'])
            residuals=[(a['subtitleStart']-(old_rate*a['asrStart']+prior))/old_rate for a in anchors] if prior is not None else []
            innovation=abs((rate*end+intercept)-(old_rate*end+prior))/rate if prior is not None else 0
            if innovation>.9:
                jumps=session.setdefault('clockJump',[])
                jumps[:]=[j for j in jumps if end-j['end']<=30 and abs(j['offset']-(rate*end+intercept-end))<.5]
                jumps.append(dict(end=end,offset=rate*end+intercept-end,cues=[a['cue'] for a in anchors]))
                confirmed=(len({j['end'] for j in jumps})>=2 and
                    max(j['end'] for j in jumps)-min(j['end'] for j in jumps)>=6 and
                    len({cue for j in jumps for cue in j['cues']})>=4)
                if not confirmed:
                    session.pop('sourceModel',None);session.pop('transportAt',None)
                    session['reference']=None;session['windows']=[w for w in session['windows'] if w['end']<=start]
                    session['points']=old_points
                    self.event('acoustic_clock_rejected',session=token,epoch=epoch,start=start,end=end,innovationSeconds=innovation)
                    return
                session['points']={a['cue']:dict(cue=a['cue'],sourcePts=a['asrStart'],subtitleStart=a['subtitleStart']) for a in anchors}
                self.event('acoustic_clock_jump_confirmed',session=token,epoch=epoch,start=start,end=end,innovationSeconds=innovation)
            session.pop('clockJump',None)
            session['acceptedClock']=dict(page=candidate['page'],rate=rate,intercept=intercept)
            warm_rate=bool(candidate is session.get('priorReference') and session.get('priorRateVerified',False) and abs(rate-session.get('priorRate',rate))<1e-8)
            session.update(lastMatchedReference=candidate,reference=candidate,intercept=intercept,rate=rate,rateVerified=clock_rate_confident(points,rate,intercept) or warm_rate,unmatchedWindows=0,exhausted=False)
            prior_model=session.get('sourceModel')
            resuming=bool(warm_rate and prior_model and prior_model['epoch']!=epoch and session.get('acousticResumeEpoch')!=epoch)
            pending=session.get('pendingTransport')
            inherited=bool(prior_model and prior_model['reference']['page']==candidate['page'] and prior_model['rate']==rate and clock and prior_model['clock']['epoch']==clock['epoch'] and abs(prior_model['intercept']-intercept)/rate<=.75)
            if clock and (session.get('rateVerified',False) or inherited):
                session['sourceModel']=dict(asset=asset,programme=self.programme['key'],epoch=epoch,clock=clock,reference=candidate,rate=rate,intercept=intercept,verifiedAt=time.time(),notBefore=prior_model.get('notBefore',0) if inherited else 0)
            # Refresh only observed movie windows; ad intervals remain excluded.
            trusted_rate=session.get('rateVerified',False) or candidate is session.get('priorReference') and session.get('priorRateVerified',False) and abs(rate-session.get('priorRate',rate))<1e-8
            movie_end=max(end+12,position+12) if trusted_rate else end+12
            tracks=[]
            for language,cues in candidate['tracks'].items():
                emitted=[dict(index=c['index'],start=(c['start']-intercept)/rate,end=(c['end']-intercept)/rate,text=c['text']) for c in cues if c['end']>=rate*start+intercept and c['start']<=rate*movie_end+intercept]
                if emitted:tracks.append(dict(language=language,verified=True,cues=emitted))
            session['windows']=[w for w in session['windows'] if w['end']<=start and w['end']>end-180]
            session['windows'].append(dict(start=start,end=movie_end,state='LOCKED',program=self.programme['movieId'],asset=asset,tracks=tracks))
            self.event('client_acoustic_lock',referenceId=hashlib.sha256(candidate['page'].encode()).hexdigest(),session=token,epoch=epoch,start=start,end=end,rate=rate,intercept=intercept,anchors=anchors,residualSeconds=residuals,clockRateVerified=session['rateVerified'],clockRateReused=warm_rate)
            if resuming:
                session['acousticResumeEpoch']=epoch
                if clock:session['transportAt']=time.time()
                self.event('client_acoustic_clock_resume',session=token,epoch=epoch,referenceId=hashlib.sha256(candidate['page'].encode()).hexdigest(),start=start,end=end,rate=rate,intercept=intercept,confirmationCues=[a['cue'] for a in anchors],transportProposalErrorSeconds=(intercept-pending['intercept'])/rate if pending else None)
                session.pop('pendingTransport',None);session.pop('adStart',None);session.pop('adClockStart',None)
    def set_language(self,token,language):
        if language not in LANGUAGES:raise ValueError('unsupported_language')
        with self.lock:
            session=self.sessions[token]
            if language!=session['language']:
                session['language']=language
                if hasattr(self,'requested_languages'):self.fetch_subtitles(language)

    def refresh_reference_languages(self,session):
        previous=session.get('reference')
        if not previous:return
        current=next((c for c in self.candidates or [] if c is not previous and c['page']==previous['page'] and c['tracks']['en']==previous['tracks']['en']),None)
        if current is None:return
        # Only an identical English edition may reuse a verified clock. Added
        # languages have already passed the persistent cache's exact cue grid.
        for window in session['windows']:
            if window.get('state')!='LOCKED':continue
            english=next((t['cues'] for t in window['tracks'] if t['language']=='en'),None)
            if english is None:continue
            tracks=[]
            for language,cues in current['tracks'].items():
                by_index={c['index']:c for c in cues}
                translated=[{**c,'text':by_index[c['index']]['text']} for c in english if c['index'] in by_index]
                if len(translated)==len(english):tracks.append(dict(language=language,verified=True,cues=translated))
            window['tracks']=tracks
        session['reference']=current
        if session.get('sourceModel'):session['sourceModel']['reference']=current

    def response(self,token,position=None):
        with self.lock:
            s=self.sessions[token];self.refresh_reference_languages(s);s['lastAccess']=time.time();valid=self.valid_context(s['source'],None)
            phase='programme_unavailable' if not valid else 'service_unavailable' if self.discovery_error else 'searching' if self.candidates is None else 'unavailable' if not self.candidates or s['exhausted'] else 'matched' if s['reference'] else 'synchronizing'
            return dict(transportClockVerified=bool(s.get('transportAt') and time.time()-s['transportAt']<=15 and s['reference'] and not s.get('ad')),session=token,source=s['source'],clientClock=True,playbackReady=False,playbackUrl=s['source'],programmeKey=self.programme['key'],programme=self.programme,mediaClockOrigin=0,subtitleStatus=dict(phase=phase,candidateCount=len(self.candidates or []),resourceLanguages=sorted({language for candidate in self.candidates or [] for language in candidate['tracks']}),availableLanguages=sorted(s['reference']['tracks']) if s['reference'] else [],cacheHit=bool(self.candidates and all(c.get('cacheHit') for c in self.candidates))),windows=s['windows'] if valid and s['programmeKey']==self.programme['key'] else [])
    def guide_failed(self,error):
        with self.lock:
            age=time.time()-self.last_guide_success
            # Retain the current verified programme only inside its scheduled
            # interval and the existing 120-second freshness limit.
            self.gap=age>120 or time.time()>=self.programme['stopUtc']
            self.event('programme_poll_failed',errorType=type(error).__name__,
                       lastGoodAgeSeconds=round(age,3),retainedCurrentProgramme=not self.gap)
    def maintain_once(self):
        if self.stop_event.is_set():return
        with self.lock:
            self.sessions={t:s for t,s in self.sessions.items() if time.time()-s['lastAccess']<=180}
        if time.monotonic()<self.next_guide:return
        self.next_guide=time.monotonic()+25
        try:
            source,programme=self.guide()
            with self.lock:
                changed=programme['key']!=self.programme['key'];self.source,self.programme=source,programme
                self.last_guide_success=time.time();self.gap=False
                if changed:self.discovery_generation+=1;self.candidates=None
                if changed or self.discovery_error and time.monotonic()-self.last_discovery>60:
                    for language in {'en',*(s['language'] for s in self.sessions.values())}:self.fetch_subtitles(language)
        except Exception as error:self.guide_failed(error)

    def maintain(self):
        while not self.stop_event.wait(1):self.maintain_once()
