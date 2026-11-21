"""One independently verified EPG/alignment state per channel, shared file cache."""
import json
import hashlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import sys
import threading
import time
from urllib.parse import urlsplit
from client_clock import TextHub
from programme_guide import ProgrammeGuide, is_player_epg, route_key


class MultiTextHub:
    client_only=True
    prewarm=False
    engine=None
    gap=False
    programme={}
    def __init__(self,root,cache,guide=None,hub_factory=TextHub,maintenance=True):
        self.root=Path(root);self.root.mkdir(parents=True,exist_ok=True)
        self.cache=cache;self.guide=guide or ProgrammeGuide();self.hub_factory=hub_factory
        self.lock=threading.RLock();self.channels={};self.created={};self.last_guide_success=time.time()
        self.traffic=dict(receivedJsonBytes=0,sentJsonBytes=0,outboundRequests=0,outboundMediaRequests=0,outboundHosts={})
        def audit(event,args):
            if event=='urllib.Request':
                u=urlsplit(args[0]);h=u.hostname or '';self.traffic['outboundRequests']+=1
                self.traffic['outboundHosts'][h]=self.traffic['outboundHosts'].get(h,0)+1
                if u.path.endswith(('.m3u8','.ts','.mp4','.m4s')):self.traffic['outboundMediaRequests']+=1
        sys.addaudithook(audit)
        self.stop_event=threading.Event();self.pending={}
        self.pool=ThreadPoolExecutor(max_workers=4,thread_name_prefix='epg-refresh')
        self.maintenance_thread=threading.Thread(target=self.maintain,daemon=True) if maintenance else None
        if self.maintenance_thread:self.maintenance_thread.start()

    def close(self):
        self.stop_event.set()
        if self.maintenance_thread:self.maintenance_thread.join(timeout=5)
        self.pool.shutdown(wait=True,cancel_futures=True)
        with self.lock:children=list(self.channels.values())
        for child in children:
            if hasattr(child,'close'):child.close()
            else:child.stop_event.set()

    def maintain(self):
        while not self.stop_event.wait(1):
            for child,future in list(self.pending.items()):
                if future.done():
                    del self.pending[child]
                    try:future.result()
                    except Exception as error:self.event('channel_maintenance_failed',errorType=type(error).__name__)
            with self.lock:
                for cid,child in list(self.channels.items()):
                    with child.lock:idle=not child.sessions
                    if idle and time.time()-self.created[cid]>180 and child not in self.pending:
                        child.stop_event.set();del self.channels[cid];del self.created[cid]
                children=list(self.channels.values())
            for child in children:
                if child not in self.pending and not child.stop_event.is_set():
                    self.pending[child]=self.pool.submit(child.maintain_once)

    def event(self,kind,**facts):
        with (self.root/'client-clock-events.jsonl').open('a') as f:f.write(json.dumps(dict(event=kind,wall=time.time(),**facts))+'\n')
    @property
    def active_session_count(self):
        # Health must remain readable while an individual viewer is aligning.
        return sum(len(child.sessions) for child in self.channels.copy().values())

    @property
    def sessions(self):
        with self.lock:children=list(self.channels.values())
        result={}
        for child in children:
            with child.lock:result.update(child.sessions)
        return result
    def owner(self,token):
        with self.lock:children=list(self.channels.values())
        for child in children:
            with child.lock:
                if token in child.sessions:return child
        raise KeyError('expired_session')
    def valid_context(self,source,programme,token=None):
        try:
            if token is not None:
                return self.owner(token).valid_context(source,programme)
            c=self.guide.channel(source)
            with self.lock:child=self.channels.get(c['id'])
            return bool(child and child.valid_context(source,programme))
        except (ValueError,KeyError,OSError):return False
    def create(self,source,context,language,features=()):
        channel,initial=self.guide.resolve(source,context);cid=channel['id']
        local = is_player_epg(initial[1])
        key = cid
        if local:
            # Different clients may legitimately choose different mappings for
            # the same route. Never replace the shared authoritative hub.
            digest = hashlib.sha256(repr((route_key(source), initial[1]['key'])).encode()).hexdigest()
            key = f'{cid}-player-{digest}'
        with self.lock:
            for old_key,child in list(self.channels.items()):
                if not child.sessions and time.time()-self.created[old_key]>180:
                    child.stop_event.set();del self.channels[old_key];del self.created[old_key]
            if key not in self.channels:
                if len(self.channels)>=32:raise RuntimeError('active_channel_capacity')
                initial_once=[initial]
                def current():
                    if initial_once:return initial_once.pop()
                    if local:
                        if time.time()>=initial[1]['stopUtc'] or not validates(source):
                            raise ValueError('stale_player_programme')
                        return initial
                    return self.guide.current(cid,source)
                def validates(candidate):
                    try:return (not local or route_key(candidate)==route_key(source)) and self.guide.channel(candidate)['id']==cid
                    except (ValueError,KeyError,OSError):return False
                extra = {'discovery_identity': self.guide.player_search_identity} if local else {}
                child=self.hub_factory(self.root/key,self.cache,current,traffic=self.traffic,source_validator=validates,auto_maintain=False,**extra)
                self.channels[key]=child;self.created[key]=time.time()
            child=self.channels[key]
        return child.create(source,context,language,features)
    def set_language(self,token,language,**settings):return self.owner(token).set_language(token,language,**settings)
    def retry_search(self,token,data):return self.owner(token).retry_search(token,data)
    def ingest(self,token,data):return self.owner(token).ingest(token,data)
    def response(self,token,position=None):return self.owner(token).response(token,position)
