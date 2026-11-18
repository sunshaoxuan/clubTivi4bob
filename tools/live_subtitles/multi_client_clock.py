"""One independently verified EPG/alignment state per channel, shared file cache."""
import json
from pathlib import Path
import sys
import threading
import time
from urllib.parse import urlsplit
from client_clock import TextHub
from programme_guide import ProgrammeGuide


class MultiTextHub:
    client_only=True
    prewarm=False
    engine=None
    gap=False
    programme={}
    def __init__(self,root,cache,guide=None,hub_factory=TextHub):
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
    def event(self,kind,**facts):
        with (self.root/'client-clock-events.jsonl').open('a') as f:f.write(json.dumps(dict(event=kind,wall=time.time(),**facts))+'\n')
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
    def valid_context(self,source,programme):
        try:
            c=self.guide.channel(source)
            with self.lock:child=self.channels.get(c['id'])
            return bool(child and child.valid_context(source,programme))
        except (ValueError,KeyError,OSError):return False
    def create(self,source,context,language,features=()):
        channel,initial=self.guide.resolve(source,context);cid=channel['id']
        with self.lock:
            for key,child in list(self.channels.items()):
                if not child.sessions and time.time()-self.created[key]>180:
                    child.stop_event.set();del self.channels[key];del self.created[key]
            if cid not in self.channels:
                if len(self.channels)>=32:raise RuntimeError('active_channel_capacity')
                initial_once=[initial]
                def current():return initial_once.pop() if initial_once else self.guide.current(cid,source)
                def validates(candidate):
                    try:return self.guide.channel(candidate)['id']==cid
                    except (ValueError,KeyError,OSError):return False
                child=self.hub_factory(self.root/cid,self.cache,current,traffic=self.traffic,source_validator=validates)
                self.channels[cid]=child;self.created[cid]=time.time()
            child=self.channels[cid]
        return child.create(source,context,language,features)
    def ingest(self,token,data):return self.owner(token).ingest(token,data)
    def response(self,token,position=None):return self.owner(token).response(token,position)
