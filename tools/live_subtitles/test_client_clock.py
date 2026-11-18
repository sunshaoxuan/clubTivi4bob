import json
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch
from client_clock import TextHub

class ClientClockTests(unittest.TestCase):
    def test_added_language_reuses_only_identical_english_edition_and_clock(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);token=h.create(h.source,None,'en',['clientClockV1']);s=h.sessions[token]
            old=h.candidates[0];s.update(reference=old,asset='movie',rate=1.,intercept=100.)
            h.clock_window(s,old,0,50,1.,100.)
            before=json.loads(json.dumps(s['windows'][0]['tracks'][0]['cues']))
            japanese=[{**c,'text':'Japanese cue '+str(c['index'])} for c in old['tracks']['en']]
            h.candidates=[{**old,'tracks':{**old['tracks'],'ja':japanese}}]
            v=h.response(token);self.assertIn('ja',v['subtitleStatus']['availableLanguages'])
            self.assertEqual(s['windows'][0]['tracks'][0]['cues'],before)
            translated=s['windows'][0]['tracks'][1]['cues'];self.assertEqual([c['start'] for c in translated],[c['start'] for c in before])
            self.assertTrue(all(c['text'].startswith('Japanese cue') for c in translated))
            incompatible=[{**c,'start':c['start']+2} for c in old['tracks']['en']]
            h.candidates=[{**old,'tracks':dict(en=incompatible,fr=japanese)}]
            self.assertNotIn('fr',h.response(token)['subtitleStatus']['availableLanguages'])

    def test_language_change_from_audio_observation_requests_resource_lookup(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);token=h.create(h.source,None,'en',['clientClockV1']);h.requested_languages=set()
            with patch.object(h,'fetch_subtitles') as fetch:
                h.ingest(token,self.observation(h,language='ja'))
                fetch.assert_called_once_with('ja')
    def test_all_requested_languages_queue_behind_inflight_cache_lookup(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);h.requested_languages=set();h.discovery_busy=False
            h.discovery_generation=0;h.last_discovery=0
            entered=threading.Event();release=threading.Event();seen=set()
            class Cache:
                def get_or_discover(self,p,r,discover,requested_language):
                    if requested_language=='en':entered.set();release.wait(2)
                    seen.add(requested_language)
                    return [dict(page='same-film',tracks={language:[] for language in seen})]
            h.cache=Cache();h.fetch_subtitles('en');self.assertTrue(entered.wait(2))
            for language in ['zh-CN','zh-TW','ja','fr','es','ko']:h.fetch_subtitles(language)
            release.set();deadline=time.monotonic()+2
            while h.discovery_busy and time.monotonic()<deadline:time.sleep(.005)
            self.assertFalse(h.discovery_busy)
            self.assertEqual(seen,{'en','zh-CN','zh-TW','ja','fr','es','ko'})
            self.assertEqual(set(h.candidates[0]['tracks']),seen)
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

    def test_sparse_exact_cues_accumulate_for_two_minutes_but_never_cross_epoch(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);t=h.create(h.source,None,'en',['clientClockV1'])
            words=[dict(word='clear speech',start=1,end=2,probability=.9)]
            for serial,start in enumerate((0.,50.,100.),1):
                a=dict(cue=serial,asrStart=start+1,subtitleStart=start+101,offset=100.,words=5)
                with patch('client_clock.align',return_value=(None,[a])):
                    h.ingest(t,self.observation(h,start=start,end=start+20,serial=serial,words=words))
            self.assertIsNotNone(h.sessions[t]['reference'])
            a=dict(cue=4,asrStart=131.,subtitleStart=231.,offset=100.,words=5)
            with patch('client_clock.align',return_value=(None,[a])):
                h.ingest(t,self.observation(h,start=130.,end=150.,serial=4,epoch=2,asset='after-ad',words=words))
            self.assertIsNone(h.sessions[t]['reference'])

    def test_ad_return_keeps_verified_rate_only_for_the_same_movie_asset(self):
        for asset,expected in [('movie',True),('different-cut',False)]:
            with tempfile.TemporaryDirectory() as d:
                h=self.hub(d);t=h.create(h.source,None,'en',['clientClockV1']);s=h.sessions[t]
                s.update(epoch=1,asset='movie',lastWindow=dict(start=0,end=20),reference=h.candidates[0],lastMatchedReference=h.candidates[0],rate=1.,rateVerified=True)
                h.ingest(t,self.observation(h,start=20.,end=20.1,serial=1,epoch=2,asset='ad',ad=True))
                self.assertTrue(s['priorRateVerified'])
                h.ingest(t,self.observation(h,start=170.,end=170.1,serial=2,epoch=3,asset=asset))
                self.assertEqual(s['priorRateVerified'],expected)

    def test_only_verified_movie_rate_can_resume_with_two_new_exact_cue_prefixes(self):
        for verified in (False,True):
            with tempfile.TemporaryDirectory() as d:
                h=self.hub(d);t=h.create(h.source,None,'en',['clientClockV1'])
                s=h.sessions[t];s.update(epoch=1,asset='ad',lastWindow=dict(start=0,end=20),priorReference=h.candidates[0],priorRate=1.,priorRateVerified=verified,priorAsset='movie-return')
                words=[dict(word='clear speech',start=1,end=2,probability=.9)]
                anchors=[dict(cue=i,asrStart=20+i*3,subtitleStart=120+i*3,offset=100.,words=4) for i in (1,2)]
                with patch('client_clock.align',return_value=(None,anchors)):
                    h.ingest(t,self.observation(h,start=20.,end=40.,serial=1,epoch=2,asset='movie-return',words=words))
                self.assertEqual(h.sessions[t]['reference'] is not None,verified)

    def test_requested_language_edition_precedes_an_english_only_match(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);english=h.candidates[0]
            preferred=dict(page='preferred-edition',tracks=dict(en=english['tracks']['en'],**{'zh-CN':english['tracks']['en']}))
            h.candidates.append(preferred)
            t=h.create(h.source,None,'zh-CN',['clientClockV1'])
            words=[dict(word='clear speech',start=1,end=2,probability=.9)]
            with patch('client_clock.align',return_value=(100.,self.anchors())):
                h.ingest(t,self.observation(h,words=words))
            self.assertEqual(h.sessions[t]['reference']['page'],'preferred-edition')
            self.assertIn('zh-CN',h.response(t)['subtitleStatus']['availableLanguages'])
            h.sessions[t]['language']='en'
            with patch('client_clock.align',return_value=(100.,self.anchors())):
                h.ingest(t,self.observation(h,words=words,serial=2,language='zh-CN'))
            self.assertEqual(h.sessions[t]['language'],'zh-CN')

    def test_unmatched_requested_edition_falls_back_to_proven_english(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);english=h.candidates[0]
            h.candidates.append(dict(page='different-cut',tracks=dict(en=[],**{'zh-CN':[]})))
            t=h.create(h.source,None,'zh-CN',['clientClockV1'])
            words=[dict(word='clear speech',start=1,end=2,probability=.9)]
            def match(words,cues,start,**kwargs):return (100.,self.anchors()) if cues else (None,[])
            with patch('client_clock.align',side_effect=match):
                h.ingest(t,self.observation(h,words=words))
            self.assertEqual(h.sessions[t]['reference']['page'],english['page'])

    def test_temporary_guide_failure_retains_only_fresh_unexpired_programme(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d)
            h.guide_failed(TimeoutError())
            self.assertTrue(h.valid_context(h.source,None))
            h.last_guide_success=time.time()-121
            h.guide_failed(TimeoutError())
            self.assertFalse(h.valid_context(h.source,None))
            h.last_guide_success=time.time();h.programme['stopUtc']=time.time()-1
            h.guide_failed(TimeoutError())
            self.assertFalse(h.valid_context(h.source,None))

    def test_reviewed_master_profiles_share_identity_but_other_markets_do_not(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d)
            current=h.source.replace('production-LiveChannel-6065','production-hls-aes128-rtv-6065-playout')
            self.assertTrue(h.valid_context(current,None))
            self.assertFalse(h.valid_context(current.replace('-uk.fast.','-de.fast.'),None))
            self.assertFalse(h.valid_context(current.replace('6065','6066'),None))

    def test_slow_local_inference_projects_only_an_evidenced_rate_to_render_clock(self):
        with tempfile.TemporaryDirectory() as d:
            h=self.hub(d);t=h.create(h.source,None,'en',['clientClockV1'])
            words=[dict(word='clear speech',start=1,end=2,probability=.9)]
            def anchors(first,last):
                return [dict(cue=i,subtitleStart=100+i*8,asrStart=i*8,offset=100,words=9) for i in range(first,last)]
            with patch('client_clock.align',return_value=(100,anchors(0,5))):
                h.ingest(t,self.observation(h,end=32,position=60,words=words))
            self.assertEqual(h.sessions[t]['windows'][-1]['end'],44)
            with patch('client_clock.align',return_value=(100,anchors(3,8))):
                h.ingest(t,self.observation(h,serial=2,start=24,end=56,position=80,words=words))
            self.assertTrue(h.sessions[t]['rateVerified'])
            self.assertEqual(h.sessions[t]['windows'][-1]['end'],92)
            # The decoded PCM tap can lead the rendered ad by under one second.
            h.ingest(t,self.observation(h,serial=3,epoch=2,asset='ad',ad=True,start=90,end=91,position=89.3))
            self.assertEqual(h.sessions[t]['windows'][-1]['state'],'SUSPENDED')

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
