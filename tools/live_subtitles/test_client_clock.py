import json
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch
from client_clock import TextHub

class ClientClockTests(unittest.TestCase):
    def hub(self,root):
        h=TextHub.__new__(TextHub);h.root=Path(root);h.lock=threading.RLock();h.sessions={}
        h.source='https://action-rakuten-tv-uk.fast.rakuten.tv/v1/master/key/production-LiveChannel-6065/master.m3u8'
        h.programme=dict(key='programme',movieId='movie',stopUtc=time.time()+3600)
        h.last_guide_success=time.time();h.gap=False;h.discovery_error=False
        cues=[dict(index=i,start=100+i*3,end=102+i*3,text=f'we have number {i} here') for i in range(1,15)]
        h.candidates=[dict(page='provider',tracks=dict(en=cues))]
        return h
    def observation(self,h,**changes):
        d=dict(source=h.source,programmeKey='programme',epoch=1,asset='movie-asset',ad=False,start=0.,end=20.,serial=1,words=[])
        d.update(changes);return d
    def anchors(self):
        return [dict(cue=i,subtitleStart=100+i*3,asrStart=i*3,offset=100.,words=9) for i in range(1,5)]
    def test_text_session_never_constructs_a_video_collector(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d)
            with patch('live_engine.Collector',side_effect=AssertionError('media fetch forbidden')):
                token=h.create(h.source,None,'zh-CN',['clientClockV1']);self.assertTrue(h.response(token)['clientClock'])
                self.assertIsNone(h.engine);self.assertFalse(h.response(token)['playbackReady'])
    def test_ad_clears_future_movie_cues_and_requires_fresh_lock(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);t=h.create(h.source,None,'ja',['clientClockV1'])
            words=[dict(word='we have number',start=1,end=2,probability=.9)]
            with patch('client_clock.align',return_value=(100,self.anchors())):
                h.ingest(t,self.observation(h,words=words))
            self.assertEqual(h.response(t)['windows'][-1]['state'],'LOCKED')
            h.ingest(t,self.observation(h,serial=2,epoch=2,ad=True,asset='advert',start=20,end=26))
            self.assertEqual(h.response(t)['windows'][-1]['state'],'SUSPENDED')
            self.assertIsNone(h.sessions[t]['reference'])
            h.ingest(t,self.observation(h,serial=3,epoch=3,start=26,end=32))
            self.assertIsNone(h.sessions[t]['reference'])
            with patch('client_clock.align',return_value=(100,self.anchors())):
                h.ingest(t,self.observation(h,serial=4,epoch=3,start=26,end=40,words=words))
            self.assertEqual(h.response(t)['windows'][-1]['state'],'LOCKED')
    def test_resume_requires_two_fresh_cues_from_previously_matched_edition(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);t=h.create(h.source,None,'en',['clientClockV1'])
            words=[dict(word='we have number',start=1,end=2,probability=.9)]
            with patch('client_clock.align',return_value=(100,self.anchors())):
                h.ingest(t,self.observation(h,words=words))
            h.ingest(t,self.observation(h,serial=2,epoch=2,ad=True,asset='advert',start=20,end=26))
            anchors=self.anchors()[:2]
            with patch('client_clock.align',return_value=(None,anchors[:1])):
                h.ingest(t,self.observation(h,serial=3,epoch=3,start=26,end=40,words=words))
            self.assertIsNone(h.sessions[t]['reference'])
            with patch('client_clock.align',return_value=(None,anchors)):
                h.ingest(t,self.observation(h,serial=4,epoch=3,start=26,end=40,words=words))
            self.assertIsNotNone(h.sessions[t]['reference'])

    def test_partial_windows_accumulate_exact_onsets_but_never_across_ad(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);t=h.create(h.source,None,'en',['clientClockV1'])
            words=[dict(word='we have number',start=1,end=2,probability=.9)]
            for serial in (1,2,3):
                with patch('client_clock.align',return_value=(None,[self.anchors()[serial-1]])):
                    h.ingest(t,self.observation(h,serial=serial,words=words))
            self.assertIsNotNone(h.sessions[t]['reference'])
            h.ingest(t,self.observation(h,serial=4,epoch=2,ad=True,asset='advert',start=20,end=26))
            self.assertEqual(h.sessions[t]['pendingAnchors'],{})
            with patch('client_clock.align',return_value=(None,self.anchors()[:1])):
                h.ingest(t,self.observation(h,serial=5,epoch=3,start=26,end=40,words=words))
            self.assertIsNone(h.sessions[t]['reference'])

    def test_one_bad_clock_jump_cannot_move_captions_but_confirmed_edit_can(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);t=h.create(h.source,None,'en',['clientClockV1'])
            words=[dict(word='we have number',start=1,end=2,probability=.9)]
            with patch('client_clock.align',return_value=(100,self.anchors())):
                h.ingest(t,self.observation(h,words=words))
            def shifted(first,base):
                return [dict(cue=first+i,subtitleStart=107+base+i*3,asrStart=base+i*3,offset=107,words=9) for i in range(4)]
            with patch('client_clock.align',return_value=(107,shifted(10,20))):
                h.ingest(t,self.observation(h,serial=2,start=20,end=40,words=words))
            self.assertEqual(h.sessions[t]['intercept'],100)
            with patch('client_clock.align',return_value=(107,shifted(14,26))):
                h.ingest(t,self.observation(h,serial=3,start=26,end=46,words=words))
            self.assertEqual(h.sessions[t]['intercept'],107)

    def test_ad_preserves_known_edition_rate_and_clears_offset(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);t=h.create(h.source,None,'en',['clientClockV1'])
            words=[dict(word='we have number',start=1,end=2,probability=.9)]
            with patch('client_clock.align',return_value=(100,self.anchors())):
                h.ingest(t,self.observation(h,words=words))
            h.sessions[t]['rate']=25/24
            h.ingest(t,self.observation(h,serial=2,epoch=2,asset='advert',ad=True,start=20,end=26))
            self.assertEqual(h.sessions[t]['rate'],25/24)
            self.assertIsNone(h.sessions[t]['intercept'])
            self.assertNotIn('acceptedClock',h.sessions[t])
            with patch('client_clock.align',return_value=(None,[])) as alignment:
                h.ingest(t,self.observation(h,serial=3,epoch=3,start=26,end=40,words=words))
            self.assertEqual(alignment.call_args_list[0].kwargs['rate'],25/24)
            self.assertIsNone(h.sessions[t]['intercept'])

    def test_initial_fps_hypothesis_avoids_waiting_for_a_unit_rate_lock(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);t=h.create(h.source,None,'en',['clientClockV1'])
            words=[dict(word='clear speech',start=1,end=2,probability=.9)]
            anchors=[dict(cue=i,subtitleStart=100+(25/24)*(i*15),asrStart=i*15+shift,offset=100+(25/24)*(i*15)-i*15-shift,words=9) for i,shift in enumerate([.3,0,-.3])]
            with patch('client_clock.align',return_value=(None,anchors)):
                h.ingest(t,self.observation(h,end=40,words=words))
            self.assertIsNotNone(h.sessions[t]['reference'])
            self.assertGreater(h.sessions[t]['rate'],1.)

    def test_imdb_bound_initial_pair_still_needs_two_long_fresh_cues(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);h.candidates[0]['provenance']={'en':{'imdbId':'tt1234567'}}
            t=h.create(h.source,None,'en',['clientClockV1']);words=[dict(word='clear speech',start=1,end=2,probability=.9)]
            with patch('client_clock.align',return_value=(None,self.anchors()[:1])):
                h.ingest(t,self.observation(h,words=words))
            self.assertIsNone(h.sessions[t]['reference'])
            with patch('client_clock.align',return_value=(None,self.anchors()[:2])):
                h.ingest(t,self.observation(h,serial=2,words=words))
            self.assertIsNotNone(h.sessions[t]['reference'])

    def test_edition_switch_waits_for_failed_windows_and_independent_confirmation(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);first=h.candidates[0]
            alternate=dict(page='alternate',tracks=dict(en=[]));h.candidates.append(alternate)
            t=h.create(h.source,None,'en',['clientClockV1'])
            words=[dict(word='clear',start=i,end=i+.1,probability=.9) for i in range(10)]
            with patch('client_clock.align',return_value=(100,self.anchors())):
                h.ingest(t,self.observation(h,words=words))
            def match_alternate(words,cues,start,**kwargs):
                return (100,self.anchors()) if cues is alternate['tracks']['en'] else (None,[])
            with patch('client_clock.align',side_effect=match_alternate) as alignment:
                for serial in range(2,5):
                    h.ingest(t,self.observation(h,serial=serial,start=serial*6,end=20+serial*6,words=words))
                self.assertEqual(len(alignment.call_args_list),3)
                self.assertEqual(h.sessions[t]['candidateKey'],first['page'])
                h.ingest(t,self.observation(h,serial=5,start=30,end=50,words=words))
                self.assertEqual(h.sessions[t]['candidateKey'],first['page'])
                h.ingest(t,self.observation(h,serial=6,start=36,end=56,words=words))
                self.assertEqual(h.sessions[t]['candidateKey'],alternate['page'])

    def test_clock_and_observations_are_isolated_between_viewers(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);a=h.create(h.source,None,'en',['clientClockV1']);b=h.create(h.source,None,'en',['clientClockV1'])
            h.ingest(a,self.observation(h,ad=True));self.assertEqual(h.response(b)['windows'],[])
            with self.assertRaises(ValueError):h.ingest(a,self.observation(h))
    def test_rejects_nonfinite_or_unbounded_text(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);t=h.create(h.source,None,'en',['clientClockV1'])
            for change in [dict(start=float('nan')),dict(epoch=True),dict(words=[dict(word='x'*201,start=0,end=1,probability=.9)]),dict(end=1000)]:
                with self.assertRaises(ValueError):h.ingest(t,self.observation(h,**change))
    def test_failed_speech_does_not_leave_an_endless_sync_hint(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);t=h.create(h.source,None,'en',['clientClockV1'])
            words=[dict(word='unrelated',start=i,end=i+.1,probability=.9) for i in range(10)]
            with patch('client_clock.align',return_value=(None,[])):
                for serial in range(1,4):h.ingest(t,self.observation(h,serial=serial,words=words))
            self.assertEqual(h.response(t)['subtitleStatus']['phase'],'unavailable')
            with patch('client_clock.align',return_value=(100,self.anchors())):
                h.ingest(t,self.observation(h,serial=4,words=words))
            self.assertEqual(h.response(t)['subtitleStatus']['phase'],'matched')

    def test_expired_programme_never_emits_subtitles(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);t=h.create(h.source,None,'en',['clientClockV1']);h.programme['stopUtc']=time.time()-1
            self.assertEqual(h.response(t)['windows'],[])
            with self.assertRaises(ValueError):h.ingest(t,self.observation(h))

if __name__=='__main__':unittest.main()
