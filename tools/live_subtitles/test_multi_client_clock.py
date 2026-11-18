import tempfile
import threading
import time
import unittest
from multi_client_clock import MultiTextHub

class Guide:
    def channel(self,s):return dict(id=s)
    def current(self,c,s):return s,dict(key=c+'-programme',stopUtc=time.time()+900)
    def resolve(self,s,context):return self.channel(s),self.current(s,s)

class Child:
    def __init__(self,root,cache,guide,**kw):
        self.source,self.programme=guide();self.sessions={};self.lock=threading.RLock();self.stop_event=threading.Event()
    def create(self,s,c,l,f):
        t=(self.source[0]*32);self.sessions[t]=dict(language=l);return t
    def valid_context(self,s,p):return s==self.source
    def response(self,t,p=None):return dict(programme=self.programme,language=self.sessions[t]['language'])
    def ingest(self,t,d):self.sessions[t]['data']=d

class MultiTests(unittest.TestCase):
    def test_many_channels_share_four_refresh_workers(self):
        lock=threading.Lock();release=threading.Event();full=threading.Event();counts=dict(active=0,peak=0)
        class BlockingChild(Child):
            def maintain_once(self):
                with lock:
                    counts['active']+=1;counts['peak']=max(counts['peak'],counts['active'])
                    if counts['active']==4:full.set()
                release.wait(3)
                with lock:counts['active']-=1
        with tempfile.TemporaryDirectory() as d:
            hub=MultiTextHub(d,None,Guide(),BlockingChild)
            try:
                for i in range(12):hub.create(str(i),None,'en',[])
                self.assertTrue(full.wait(3));self.assertEqual(counts['peak'],4)
            finally:
                release.set();hub.close()
    def test_channels_languages_and_observations_are_isolated_with_shared_cache(self):
        with tempfile.TemporaryDirectory() as d:
            cache=object();hub=MultiTextHub(d,cache,Guide(),Child,maintenance=False)
            a=hub.create('action',None,'en',['clientClockV1']);b=hub.create('comedy',None,'ja',['clientClockV1'])
            hub.ingest(a,dict(epoch=2));self.assertNotIn('data',hub.owner(b).sessions[b])
            self.assertEqual(hub.response(b)['programme']['key'],'comedy-programme');self.assertEqual(hub.response(b)['language'],'ja')
            self.assertEqual(len(hub.sessions),2);self.assertFalse(hub.valid_context('unbound',None));self.assertIsNone(hub.engine)
    def test_idle_channels_are_retired_without_stopping_active_viewers(self):
        with tempfile.TemporaryDirectory() as d:
            hub=MultiTextHub(d,None,Guide(),Child,maintenance=False);a=hub.create('action',None,'en',[]);old=hub.channels['action'];old.sessions.clear();hub.created['action']=time.time()-181
            hub.create('comedy',None,'en',[]);self.assertTrue(old.stop_event.is_set());self.assertNotIn('action',hub.channels)

if __name__=='__main__':unittest.main()
