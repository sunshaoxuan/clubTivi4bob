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
from live_engine import align, fit_clock_rate, clock_rate_confident, short_cue_clock_evidence, short_cue_clock_cluster
from subtitle_cache import RETRY_TTL
from subtitle_ai import CHINESE, TARGETS
from subtitle_edition import track_fingerprint
from subtitle_catalog import discover, LANGUAGES
from subtitle_variants import SubtitleVariants, UNCHANGED
from service import reviewed_pilot_source
from transport_clock import clock as source_clock, project as project_clock
from semantic_dialogue import SemanticDialogue


def finite(value, low, high):
    if isinstance(value,bool) or not isinstance(value,(int,float)) or not math.isfinite(value) or not low<=value<=high:
        raise ValueError('invalid_clock_observation')
    return float(value)


TRANSLATION_SLOTS = threading.BoundedSemaphore(2)


class TextHub:
    client_only=True
    prewarm=False
    engine=None
    def __init__(self,root,cache,guide,*,traffic=None,source_validator=None,auto_maintain=True,
                 discovery_identity=None):
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
        self.discovery_identity=discovery_identity
        self.source_validator=source_validator;self.stop_event=threading.Event()
        self.requested_languages=set()
        self.manual_searches=set()
        self.searching_language=None
        self.lock=threading.RLock();self.sessions={};self.candidates=None;self.discovery_error=False
        self.source,self.programme=self.guide();self.last_guide_success=time.time();self.gap=False
        self.discovery_thread=None
        self.discovery_generation=0;self.last_discovery=0;self.discovery_busy=False
        self.fetch_subtitles()
        self.next_guide=time.monotonic()+25
        if auto_maintain:threading.Thread(target=self.maintain,daemon=True).start()
    def event(self,kind,**facts):
        with (self.root/'client-clock-events.jsonl').open('a') as f:
            f.write(json.dumps(dict(event=kind,wall=time.time(),**facts))+'\n')
    def retry_search(self, token, data):
        with self.lock:
            session = self.sessions[token]
            language = data.get('language')
            if (language not in LANGUAGES or session['source'] != data.get('source')
                    or data.get('programmeKey') != self.programme['key']
                    or not self.valid_context(session['source'], data.get('programme'))
                    or not self.programme.get('searchable', True)):
                raise ValueError('current_programme_required')
            session.pop('semanticState',None)
            self.fetch_subtitles(language, refresh=True)

    def fetch_subtitles(self,language='en',*,refresh=False):
        with self.lock:
            if getattr(self,'stop_event',None) and self.stop_event.is_set():return
            if refresh:
                self.manual_searches.add(language)
            self.requested_languages.add(language)
            if self.discovery_busy:return
            self.discovery_busy=True
        def work():
            while True:
                with self.lock:
                    if (getattr(self,'stop_event',None) and self.stop_event.is_set()) or not self.requested_languages:
                        self.searching_language=None
                        self.discovery_busy=False;self.last_discovery=time.monotonic();return
                    manual = getattr(self, 'manual_searches', set())
                    language = next(iter(manual), None) or next(iter(self.requested_languages))
                    self.requested_languages.remove(language)
                    refresh = language in manual
                    manual.discard(language)
                    self.searching_language = language
                    generation = self.discovery_generation
                    programme = dict(self.programme)
                try:
                    options = dict(requested_language=language)
                    if refresh:
                        options['refresh'] = True
                    identity = getattr(self, 'discovery_identity', None)
                    lookup = identity(programme) if identity is not None else programme
                    resolver=getattr(self.cache,'resolve_programme',None)
                    if lookup and resolver is not None:lookup=resolver(lookup)
                    candidates = self.cache.get_or_discover(
                        lookup, self.root/'discovery'/uuid.uuid4().hex, discover, **options
                    ) if lookup and lookup.get('searchable', True) else []
                    variants=SubtitleVariants(candidates)
                    with self.lock:
                        if generation==self.discovery_generation:
                            candidates=self.preserve_generated(self.candidates,candidates)
                            self.candidates=candidates
                            self.resource_identity=dict(lookup) if lookup else None
                            self.resource_identity_programme=programme['key']
                            self.variants=SubtitleVariants(candidates)
                            self.discovery_error=False
                    self.event('subtitle_resources_ready',programmeKey=programme['key'],language=language,candidates=len(candidates),manual=refresh)
                except Exception as e:
                    with self.lock:
                        if generation==self.discovery_generation:self.discovery_error=not bool(self.candidates)
                    self.event('subtitle_discovery_error',language=language,errorType=type(e).__name__)
        thread=threading.Thread(target=work,daemon=True)
        self.discovery_thread=thread
        thread.start()
    def ensure_translation(self, session):
        """Schedule outside playback/HTTP work, once the English clock is proven."""
        cache=getattr(self,'cache',None);ai=getattr(cache,'ai',None)
        language=session.get('language');reference=session.get('reference')
        identity=getattr(self,'resource_identity',None)
        if (not ai or not ai.enabled or language not in TARGETS or not reference or
                reference['tracks'].get(language) and not reference.get('provenance',{}).get(language,{}).get('partial')
                or session.get('variantId') and not self.ai_track(reference,language) or session.get('ad')
                or not reference['tracks'].get('en') or not identity or
                getattr(self,'resource_identity_programme',None)!=self.programme['key']
                or not hasattr(cache,'with_ai_translation')):
            return None
        fingerprint=track_fingerprint(reference['tracks']['en'])
        key=(self.programme['key'],language,reference['page'],fingerprint)
        jobs=getattr(self,'translation_jobs',None)
        if jobs is None:self.translation_jobs=jobs={}
        job=jobs.get(key)
        if job and (job['running'] or time.monotonic()-job['finished']<30):
            return dict(language=language,**ai.translation_status(reference['tracks']['en'],language))
        if sum(row['running'] for row in jobs.values())>=2:return dict(language=language,phase='queued')
        for old in list(jobs):
            if not jobs[old]['running'] and old[0]!=self.programme['key']:jobs.pop(old)
        if not TRANSLATION_SLOTS.acquire(blocking=False):return dict(language=language,phase='queued')
        generation=self.discovery_generation
        programme=dict(identity);candidates=list(self.candidates or [])
        if not any(c['page']==reference['page'] and c['tracks'].get('en')==reference['tracks']['en'] for c in candidates):
            candidates.append(reference)
        jobs[key]=dict(running=True,finished=0)
        def cancelled():
            return (getattr(self,'stop_event',threading.Event()).is_set() or
                    self.discovery_generation!=generation or self.programme['key']!=key[0] or
                    not any(s.get('language')==language and s.get('programmeKey')==key[0]
                            and s.get('lastAccess',0)>time.time()-120 for s in self.sessions.copy().values()))
        last_priority=[session.get('rate',1)*(session.get('lastWindow') or {}).get('end',0)+(session.get('intercept') or 0)]
        def priority():
            latest=next((viewer for viewer in self.sessions.copy().values()
                         if viewer.get('language')==language and not viewer.get('ad')
                         and (viewer.get('reference') or {}).get('page')==reference['page']
                         and viewer.get('intercept') is not None),None)
            if latest is not None:
                last_priority[0]=latest.get('rate',1)*(latest.get('lastWindow') or {}).get('end',0)+latest['intercept']
            return last_priority[0]
        def publish(result):
            generated=next((c for c in result if c['page']==reference['page']
                and self.ai_track(c,language)),None)
            with self.lock:
                if cancelled() or not generated:return
                merged=[]
                for candidate in self.candidates or []:
                    if (candidate['page']==reference['page']
                            and candidate['tracks'].get('en')==reference['tracks']['en']
                            and (not candidate['tracks'].get(language) or self.ai_track(candidate,language))):
                        candidate={**candidate,'tracks':{**candidate['tracks'],language:generated['tracks'][language]},
                            'provenance':{**candidate.get('provenance',{}),language:generated['provenance'][language]}}
                    merged.append(candidate)
                if not any(c['page']==reference['page'] and c['tracks'].get('en')==reference['tracks']['en'] for c in merged):
                    merged.append(generated)
                self.candidates=merged;self.variants=SubtitleVariants(merged)
                self.event('subtitle_translation_progress' if generated['provenance'][language].get('partial')
                           else 'subtitle_translation_ready',programmeKey=key[0],language=language,
                           cues=len(generated['tracks'][language]))
        def work():
            self.event('subtitle_translation_started',programmeKey=key[0],language=language)
            try:
                result=cache.with_ai_translation(programme,candidates,language,
                    reference_page=reference['page'],cancelled=cancelled,
                    priority_time=priority,on_progress=publish)
                publish(result)
            except Exception as error:
                self.event('subtitle_translation_retry',programmeKey=key[0],language=language,errorType=type(error).__name__)
            finally:
                with self.lock:jobs[key].update(running=False,finished=time.monotonic())
                TRANSLATION_SLOTS.release()
        threading.Thread(target=work,name='subtitle-translation',daemon=True).start()
        return dict(language=language,phase='queued')

    @classmethod
    def preserve_generated(cls, previous, candidates):
        """Provider refreshes must not erase a completed translation every minute."""
        merged=[]
        for candidate in candidates:
            additions={};facts={}
            for old in previous or []:
                if (old['page']!=candidate['page'] or
                        old['tracks'].get('en')!=candidate['tracks'].get('en')):continue
                for language,cues in old['tracks'].items():
                    if cls.ai_track(old,language) and not candidate['tracks'].get(language):
                        additions[language]=cues;facts[language]=old['provenance'][language]
            merged.append({**candidate,'tracks':{**candidate['tracks'],**additions},
                'provenance':{**candidate.get('provenance',{}),**facts}} if additions else candidate)
        return merged

    def close(self):
        self.stop_event.set()
        thread=getattr(self,'discovery_thread',None)
        if thread and thread is not threading.current_thread():
            thread.join(timeout=45)

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
    def variant_catalog(self):
        catalog = getattr(self, 'variants', None)
        if catalog is None or catalog.candidates is not self.candidates:
            catalog = self.variants = SubtitleVariants(self.candidates)
        return catalog

    def caption_tracks(self, candidate, start, end, rate, intercept):
        catalog = self.variant_catalog()
        tracks = []
        for language, cues in candidate['tracks'].items():
            generated = self.ai_track(candidate, language)
            if generated and candidate.get('provenance',{}).get(language,{}).get('partial'):
                required={c['index'] for c in candidate['tracks'].get('en',[])
                          if c['end']>=rate*start+intercept and c['start']<=rate*end+intercept}
                if not required.issubset({c['index'] for c in cues}):continue
            emitted = [dict(index=cue['index'], start=(cue['start']-intercept)/rate,
                            end=(cue['end']-intercept)/rate,
                            text=('[AI] ' if generated else '') + cue['text'])
                       for cue in cues if cue['end'] >= rate*start+intercept
                       and cue['start'] <= rate*end+intercept]
            if emitted:
                track = dict(language=language, verified=True, cues=emitted)
                choice = catalog.track(candidate, language)
                if choice:
                    track['variantId'] = choice['id']
                tracks.append(track)
        return tracks

    @staticmethod
    def ai_track(candidate, language):
        return bool(candidate and candidate.get('provenance',{}).get(language,{}).get('generated'))

    @classmethod
    def preferred_track(cls, candidate, preferred):
        if not candidate:
            return None
        languages = [preferred]
        if preferred in CHINESE:
            languages.extend(tag for tag in CHINESE if tag != preferred)
        return next((tag for tag in (*languages,'en') if tag in candidate['tracks']),None)

    def clock_window(self, session, candidate, start, end, rate, intercept):
        tracks = self.caption_tracks(candidate, start, end, rate, intercept)
        session['windows'] = [window for window in session['windows']
                              if window['end'] <= start and window['end'] > end-180]
        session['windows'].append(dict(start=start, end=end, state='LOCKED',
            program=self.programme['movieId'], asset=session['asset'],
            tracks=tracks, subtitleClock=dict(rate=rate, intercept=intercept)))

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
            if words and not ad:
                speech=data.get('audioLanguage','en')
                if not isinstance(speech,str) or speech not in LANGUAGES:raise ValueError('unsupported_language')
                prior_speech=session.get('audioLanguage')
                if prior_speech is not None and speech!=prior_speech:
                    if delayed or epoch<session['audioLanguageEpoch']:return
                    # A noisy auto-detected window cannot replace a verified
                    # language in the same audio epoch. Before a lock, a later
                    # usable window may correct the initial language guess.
                    if epoch==session['audioLanguageEpoch'] and session.get('rateVerified',False):return
                if prior_speech!=speech and hasattr(self,'requested_languages'):
                    self.fetch_subtitles(speech)
            changed=(session['epoch']!=epoch or session['asset']!=asset or session['programmeKey']!=self.programme['key'])
            if changed:
                session.pop('semanticState',None)
                session.pop('semanticClockLimit',None)
                session.pop('pendingTransport',None)
                session.pop('clockJump',None);session.pop('acceptedClock',None);session.pop('editionSwitch',None)
                session.pop('sparseClockProposal',None)
                if session['programmeKey']!=self.programme['key']:
                    session.pop('variantId',None)
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
                session.pop('semanticState',None)
                session.pop('semanticClockLimit',None)
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
            preferred=[c for c in self.candidates or [] if self.preferred_track(c,session['language']) not in (None,'en')]
            # Prove the requested language's edition first. An already matched
            # fallback remains available until a preferred edition is verified.
            trial=([known] if self.preferred_track(known,session['language']) not in (None,'en') else preferred[:])
            if known is not None and known not in trial:trial.append(known)
            if known is None or session['unmatchedWindows']>=3:
                trial += [c for c in self.candidates or [] if c not in trial]
            if pinned := session.get('variantId'):
                trial = self.variant_catalog().matching(pinned)
            selected=None
            for candidate in trial:
                cues=candidate['tracks'].get(speech)
                if cues is None or self.ai_track(candidate,speech):continue
                candidate_rate=session['rate'] if session.get('candidateKey')==candidate['page'] else session.get('priorRate',1.) if candidate is prior else 1.
                offset,anchors=align(words,cues,start,rate=candidate_rate,language=speech)
                # Accumulate distinct, exact cue-onset matches across overlapping
                # windows. Epoch/asset changes clear this evidence completely.
                fresh_ids={a['cue'] for a in anchors}
                pending_key=speech+':'+candidate['page']
                pending=session.setdefault('pendingAnchors',{}).setdefault(pending_key,{})
                for anchor in anchors:
                    pending[anchor['cue']]=anchor
                pending={key:a for key,a in pending.items() if end-120 <= a['asrStart'] <= end}
                session['pendingAnchors'][pending_key]=pending
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
                    ordinary=[a for a in cluster if not (a.get('shortCuePrefix'))]
                    ordinary_span=(max(a['asrStart'] for a in ordinary)-min(a['asrStart'] for a in ordinary)) if ordinary else 0
                    ordinary_proof=(len(ordinary)>=3 and ordinary_span>=4 or
                        (candidate is prior or bound) and len(ordinary)>=2 and ordinary_span>=2 and all(a['words']>=8 for a in ordinary) or
                        candidate is prior and session.get('priorRateVerified',False) and len(ordinary)>=2 and ordinary_span>=2 and all(a['words']>=4 for a in ordinary))
                    if any(a.get('shortCuePrefix') for a in cluster):
                        if ordinary_proof:cluster=ordinary
                        else:
                            cluster=short_cue_clock_cluster(projected,fresh_ids)
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
            matcher=getattr(self,'semantic_matcher',None)
            if selected is None and clock is not None:
                ai=getattr(getattr(self,'cache',None),'ai',None)
                if matcher is None and ai is not None:
                    matcher=self.semantic_matcher=SemanticDialogue(ai,self.lock,lambda:self.sessions,
                        lambda:self.candidates,self.event)
                if matcher is not None:
                    selected=matcher.take(session,trial,end,speech,token)
                    identity=(getattr(self,'resource_identity',None) if
                              getattr(self,'resource_identity_programme',None)==self.programme['key'] else None)
                    model=session.get('sourceModel',{})
                    refresh_semantic=(projected and model.get('semanticDialogue') and
                        model.get('maxAgeSeconds',1800)-(time.time()-model.get('verifiedAt',0))<=180)
                    if selected is None and ((not projected and session['unmatchedWindows']>=2) or refresh_semantic):
                        for candidate in trial:
                            if matcher.offer(token,session,identity,candidate,speech,words,start,end):break
            if selected is None:
                if prior_speech is not None and speech!=prior_speech:
                    self.event('unmatched_speech_language',session=token,epoch=epoch,language=speech)
                    return
                if len(words)>=10:
                    session['unmatchedWindows']+=1;session['exhausted']=not projected and session['unmatchedWindows']>=3
                    if not projected:
                        session['reference']=None;session['intercept']=None;session['windows']=[w for w in session['windows'] if w['end']<=start]
                    self.event('unmatched_speech',session=token,start=start,end=end,words=len(words))
                return
            candidate,anchors,selected_rate=selected
            semantic_verified=any(a.get('semanticDialogue') for a in anchors)
            if not semantic_verified:session.pop('semanticState',None)
            if prior_speech is not None and speech!=prior_speech:
                for key in ('priorReference','lastMatchedReference','sourceModel','transportAt','pendingTransport','candidateKey','priorRate','priorRateVerified','priorAsset','adStart','adClockStart','acceptedClock','editionSwitch','clockJump'):
                    session.pop(key,None)
                session.update(reference=None,windows=[],intercept=None,rate=1.,rateVerified=False,points={},unmatchedWindows=0,exhausted=False)
            session['audioLanguage']=speech
            session['audioLanguageEpoch']=epoch
            if session.get('adStart') is not None:
                exact=[a for a in anchors if not (a.get('fuzzyPrefix') or a.get('sparseWords') or a.get('semanticDialogue')) and a['words']>=4]
                enough_exact=(len({a['cue'] for a in exact})>=2 and
                    max(a['asrStart'] for a in exact)-min(a['asrStart'] for a in exact)>=2)
                if not enough_exact and not short_cue_clock_evidence(anchors) and not semantic_verified:
                    return
                if enough_exact:anchors=exact
            accepted=session.get('acceptedClock',{})
            if any(anchor.get('sparseWords') for anchor in anchors):
                offset = statistics.median(a['subtitleStart'] - selected_rate * a['asrStart'] for a in anchors)
                trusted = (accepted.get('page') == candidate['page']
                           and abs(accepted['intercept'] - offset) < .6)
                if not trusted:
                    proposal = session.get('sparseClockProposal')
                    cue_ids = {a['cue'] for a in anchors}
                    agrees = (proposal and proposal['page'] == candidate['page']
                              and 3 <= end - proposal['end'] <= 40
                              and abs(proposal['intercept'] - offset) < .55
                              and bool(cue_ids - proposal['cueIds']))
                    if not agrees:
                        if (not proposal or proposal['page'] != candidate['page']
                                or end - proposal['end'] > 40
                                or abs(proposal['intercept'] - offset) >= .55):
                            session['sparseClockProposal'] = dict(page=candidate['page'], end=end,
                                                                   intercept=offset, cueIds=cue_ids)
                        return
            session.pop('sparseClockProposal',None)
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
            rate=selected_rate if semantic_verified else proposal['rate'] if proposal else session['rate'] if session.get('rateVerified',False) else selected_rate
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
                if semantic_verified:
                    session['sourceModel'].update(semanticDialogue=True,maxAgeSeconds=session.pop('semanticClockLimit',1800))
            # Refresh only observed movie windows; ad intervals remain excluded.
            trusted_rate=session.get('rateVerified',False) or candidate is session.get('priorReference') and session.get('priorRateVerified',False) and abs(rate-session.get('priorRate',rate))<1e-8
            movie_end=max(end+12,position+12) if trusted_rate else end+12
            self.clock_window(session,candidate,start,movie_end,rate,intercept)
            self.event('client_acoustic_lock',referenceId=hashlib.sha256(candidate['page'].encode()).hexdigest(),session=token,epoch=epoch,start=start,end=end,rate=rate,intercept=intercept,anchors=anchors,residualSeconds=residuals,clockRateVerified=session['rateVerified'],clockRateReused=warm_rate,alignmentMethod='semantic_dialogue' if semantic_verified else 'exact_dialogue')
            if resuming:
                session['acousticResumeEpoch']=epoch
                if clock:session['transportAt']=time.time()
                self.event('client_acoustic_clock_resume',session=token,epoch=epoch,referenceId=hashlib.sha256(candidate['page'].encode()).hexdigest(),start=start,end=end,rate=rate,intercept=intercept,confirmationCues=[a['cue'] for a in anchors],transportProposalErrorSeconds=(intercept-pending['intercept'])/rate if pending else None)
                session.pop('pendingTransport',None);session.pop('adStart',None);session.pop('adClockStart',None)
    def set_language(self, token, language, variant=UNCHANGED):
        if language not in LANGUAGES:
            raise ValueError('unsupported_language')
        with self.lock:
            session = self.sessions[token]
            if variant is UNCHANGED and session.get('variantId'):
                # A delayed audio request cannot undo the picker selection.
                return
            if language != session['language']:
                session['language'] = language
                if hasattr(self, 'requested_languages'):
                    self.fetch_subtitles(language)
            if variant is UNCHANGED:
                return
            if variant is not None and (not isinstance(variant, str) or not re.fullmatch(r'[a-f0-9]{64}', variant)):
                raise ValueError('invalid_subtitle_variant')
            catalog = self.variant_catalog()
            reference = session.get('reference')
            if variant and not catalog.matching(variant) and not catalog.supports(reference, variant):
                variant = None
            if variant == session.get('variantId'):
                return
            session['variantId'] = variant
            if not variant:
                return
            if catalog.supports(reference, variant):
                return
            speech = session.get('audioLanguage', 'en')
            acoustic_key = catalog.key(reference, speech)
            equivalent = next((candidate for candidate in catalog.matching(variant)
                               if acoustic_key and catalog.key(candidate, speech) == acoustic_key), None)
            if equivalent is not None and not session.get('ad'):
                self.replace_reference(session, equivalent)
                return
            # Another cut requires fresh acoustic evidence. Ads stay suspended.
            for key in ('lastMatchedReference', 'priorReference', 'priorRate',
                        'priorRateVerified', 'priorAsset', 'sourceModel', 'transportAt',
                        'pendingTransport', 'candidateKey', 'acceptedClock',
                        'editionSwitch', 'clockJump', 'sparseClockProposal'):
                session.pop(key, None)
            session.update(reference=None, intercept=None, rate=1., rateVerified=False,
                           points={}, pendingAnchors={}, unmatchedWindows=0, exhausted=False,
                           windows=[window for window in session['windows'] if window['state'] == 'SUSPENDED'])

    def replace_reference(self, session, candidate):
        for window in session['windows']:
            if window.get('state') != 'LOCKED' or 'subtitleClock' not in window:
                continue
            window['tracks'] = self.caption_tracks(candidate, window['start'], window['end'],
                                                   **window['subtitleClock'])
        session['reference'] = session['lastMatchedReference'] = candidate
        session['candidateKey'] = candidate['page']
        if session.get('acceptedClock'):
            session['acceptedClock']['page'] = candidate['page']
        if session.get('sourceModel'):
            session['sourceModel']['reference'] = candidate

    def refresh_reference_languages(self, session):
        previous = session.get('reference')
        if not previous or session.get('variantId'):
            return
        speech = session.get('audioLanguage', 'en')
        preferred = session['language']
        selection = lambda candidate: self.preferred_track(candidate,preferred)
        def rank(candidate):
            tag = selection(candidate)
            return (tag==preferred, tag not in (None,'en'), not self.ai_track(candidate,tag))
        compatible = (candidate for candidate in self.candidates or []
                      if candidate is not previous
                      and (candidate['page'] == previous['page']
                           or rank(candidate)>rank(previous))
                      and candidate['tracks'].get(speech) == previous['tracks'].get(speech)
                      and (self.ai_track(previous,selection(previous)) and rank(candidate)>rank(previous)
                           or all(self.ai_track(previous,language) or
                                  candidate['tracks'].get(language) == cues
                                  for language, cues in previous['tracks'].items())))
        current = max(compatible, key=rank, default=None)
        if current is not None and rank(current)>=rank(previous):
            self.replace_reference(session, current)

    def response(self, token, position=None):
        with self.lock:
            session = self.sessions[token]
            session['lastAccess'] = time.time()
            valid = self.valid_context(session['source'], None)
            current = valid and session['programmeKey'] == self.programme['key']
            translation=None
            if current:
                self.refresh_reference_languages(session)
                translation=self.ensure_translation(session)
            catalog = self.variant_catalog()
            reference = session.get('reference') if current else None
            pinned = session.get('variantId') if current else None
            phase = ('programme_unavailable' if not valid else
                     'service_unavailable' if self.discovery_error else
                     'searching' if self.candidates is None else
                     'synchronizing' if session.get('semanticState',{}).get('inFlight') else
                     'unavailable' if not self.candidates or session['exhausted'] else
                     'matched' if reference else 'synchronizing')
            choices = catalog.choices(reference, pinned) if valid else []
            if pinned:
                active = pinned if catalog.supports(reference, pinned) and not session.get('ad') else None
            else:
                preferred = catalog.track(reference, self.preferred_track(reference,session['language']))
                active = preferred['id'] if preferred and not session.get('ad') else None
            searching = set(getattr(self, 'requested_languages', ()))
            if getattr(self, 'searching_language', None):
                searching.add(self.searching_language)
            window=session.get('lastWindow') or {}
            covered={t['language'] for t in self.caption_tracks(reference,window['start'],window['end'],session['rate'],session['intercept'])} if reference and window and session.get('intercept') is not None else set()
            available=sorted(tag for tag in reference['tracks'] if
                not reference.get('provenance',{}).get(tag,{}).get('partial') or tag in covered) if reference else []
            status = dict(phase=phase, translation=translation, candidateCount=len(self.candidates or []),
                          searchingLanguages=sorted(searching) if valid else [],
                          resourceLanguages=sorted({choice['language'] for choice in choices}),
                          availableLanguages=available,
                          cacheHit=bool(self.candidates and all(candidate.get('cacheHit') for candidate in self.candidates)),
                          variantCandidates=choices, selectedVariantId=pinned, activeVariantId=active)
            return dict(audioLanguageV1=True,
                        transportClockVerified=bool(session.get('transportAt') and time.time()-session['transportAt']<=15
                                                    and reference and not session.get('ad')),
                        session=token, source=session['source'], clientClock=True, playbackReady=False,
                        playbackUrl=session['source'], programmeKey=self.programme['key'], programme=self.programme,
                        mediaClockOrigin=0, subtitleStatus=status, windows=session['windows'] if current else [])

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
                if changed:
                    self.discovery_generation+=1
                    self.manual_searches.clear()
                    self.requested_languages.clear()
                    self.candidates=None
                    self.variants=SubtitleVariants(None)
                    for session in self.sessions.values():
                        session.pop('variantId', None)
                languages = {s['language'] for s in self.sessions.values()}
                if changed:
                    for language in languages or {'en'}:
                        self.fetch_subtitles(language)
                elif not self.discovery_busy and time.monotonic() - self.last_discovery >= RETRY_TTL:
                    available = {language for candidate in self.candidates or [] for language in candidate['tracks']
                                 if not self.ai_track(candidate,language)}
                    # An aligned fallback must not stop discovery for an active
                    # viewer. The shared cache controls each provider retry.
                    for language in languages - available:
                        self.fetch_subtitles(language)
        except Exception as error:self.guide_failed(error)

    def maintain(self):
        while not self.stop_event.wait(1):self.maintain_once()
