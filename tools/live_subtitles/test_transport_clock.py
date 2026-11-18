import time,tempfile,unittest
from unittest.mock import patch
from transport_clock import clock,project
import test_client_clock

class TransportClockTests(unittest.TestCase):
    def model(self):
        return dict(asset='movie',programme='programme',epoch=1,rate=1.,intercept=100.,verifiedAt=time.time(),clock=dict(epoch=1,audioRemoved=0.,videoRemoved=0.,updatedAt=0.))
    def proposal(self,model=None,current=None,**changes):
        args=dict(asset='movie',programme='programme',epoch=3,start=170.,position=169.3,ad_start=20.,ad_clock_start=20.,now=time.time());args.update(changes)
        return project(model or self.model(),current or dict(epoch=1,audioRemoved=-148.053333,videoRemoved=-147.925033,updatedAt=170.),**args)
    def test_captured_two_second_content_jump_is_not_ad_duration_subtraction(self):
        result=self.proposal()
        self.assertAlmostEqual(result['sourceMovieAdvanceSeconds'],2.010817,places=6)
        self.assertAlmostEqual(result['intercept'],-47.989183,places=6)
        self.assertGreaterEqual(result['start'],171.)
    def test_actual_second_break_allows_accumulated_manifest_clock_drift(self):
        result=self.proposal(start=1907.,position=1906.35,ad_start=1757.,ad_clock_start=1755.829033333,current=dict(epoch=1,audioRemoved=-149.056,videoRemoved=-148.925033333,updatedAt=1905.829033333))
        self.assertIsNotNone(result)
        self.assertAlmostEqual(result['sourceMovieAdvanceSeconds'],1.0094833335,places=6)
        self.assertIsNone(self.proposal(ad_clock_start=18.))

    def test_captured_six_second_content_jump(self):
        result=self.proposal(current=dict(epoch=1,audioRemoved=-144.042666334,videoRemoved=-143.999999667,updatedAt=170.))
        self.assertAlmostEqual(result['sourceMovieAdvanceSeconds'],5.9786669995,places=6)
    def test_captured_rebased_source_is_rejected(self):
        for audio,video in [(701.909333333,702.),(1619.925333333,1620.),(2627.925333333,2628.)]:
            self.assertIsNone(self.proposal(current=dict(epoch=1,audioRemoved=audio,videoRemoved=video,updatedAt=170.)))
    def test_changed_asset_programme_epoch_and_stale_model_are_rejected(self):
        for change in [dict(asset='other'),dict(programme='other')]:self.assertIsNone(self.proposal(**change))
        self.assertIsNone(self.proposal(current=dict(epoch=2,audioRemoved=-148,videoRemoved=-148,updatedAt=170)))
        m=self.model();m['verifiedAt']-=1801;self.assertIsNone(self.proposal(model=m))
    def test_missing_return_clock_and_disagreeing_streams_are_rejected(self):
        for c in [dict(epoch=1,audioRemoved=-148,videoRemoved=-148,updatedAt=0),dict(epoch=1,audioRemoved=-148,videoRemoved=-147,updatedAt=170)]:self.assertIsNone(self.proposal(current=c))
        self.assertIsNone(self.proposal(ad_start=None))
    def test_clock_validation_rejects_future_and_nonfinite_data(self):
        self.assertIsNone(clock(None,100))
        for c in [dict(epoch=True,audioRemoved=0,videoRemoved=0,updatedAt=0),dict(epoch=1,audioRemoved=float('nan'),videoRemoved=0,updatedAt=0),dict(epoch=1,audioRemoved=0,videoRemoved=0,updatedAt=101)]:
            with self.assertRaises(ValueError):clock(c,100)
    def fixture(self,root):
        helper=test_client_clock.ClientClockTests();h=helper.hub(root);t=h.create(h.source,None,'en',['clientClockV1']);s=h.sessions[t]
        s.update(epoch=1,asset='movie',lastWindow=dict(start=0,end=20),rateVerified=True,reference=h.candidates[0],lastMatchedReference=h.candidates[0])
        m=self.model();m['reference']=h.candidates[0];s['sourceModel']=m
        return helper,h,t
    def enter_and_propose(self,helper,h,t):
        h.ingest(t,helper.observation(h,start=20,end=20.1,epoch=2,asset='ad',ad=True,sourceClock=dict(epoch=1,audioRemoved=9000,videoRemoved=9000,updatedAt=20)))
        h.ingest(t,helper.observation(h,start=170,end=170.1,position=169.3,epoch=3,asset='movie',serial=2,sourceClock=dict(epoch=1,audioRemoved=-148,videoRemoved=-148,updatedAt=170)))
    def confirm(self,helper,h,t,offset=-48.,serial=3,epoch=3,start=170.,removed=-148.,fuzzy=False):
        anchors=[dict(cue=20+i,asrStart=start+2+i*3,subtitleStart=start+2+i*3+offset,offset=offset,words=9,fuzzyPrefix=fuzzy) for i in range(2)]
        data=helper.observation(h,start=start,end=start+20,position=start+19,epoch=epoch,asset='movie',serial=serial,sourceClock=dict(epoch=1,audioRemoved=removed,videoRemoved=removed,updatedAt=start),words=[dict(word='clear speech',start=1,end=2,probability=.9)])
        with patch('client_clock.align',return_value=(offset,anchors)):h.ingest(t,data)
    def test_ad_clock_is_only_a_proposal_until_two_fresh_cues_confirm(self):
        with tempfile.TemporaryDirectory() as root:
            helper,h,t=self.fixture(root);self.enter_and_propose(helper,h,t)
            result=h.response(t)
            self.assertFalse(result['transportClockVerified'])
            self.assertIsNone(h.sessions[t]['reference'])
            self.assertFalse(any(w['state']=='LOCKED' for w in result['windows']))
            self.confirm(helper,h,t)
            self.assertTrue(h.response(t)['transportClockVerified'])
            self.assertAlmostEqual(h.sessions[t]['intercept'],-48.)
    def test_each_successive_ad_requires_its_own_acoustic_confirmation(self):
        with tempfile.TemporaryDirectory() as root:
            helper,h,t=self.fixture(root)
            for serial,epoch,start,returned,removed,offset in [(1,2,20.,170.,-148.,-48.),(4,4,300.,450.,-292.,-192.)]:
                h.ingest(t,helper.observation(h,start=start,end=start+.1,epoch=epoch,asset='ad',ad=True,serial=serial,sourceClock=dict(epoch=1,audioRemoved=9000,videoRemoved=9000,updatedAt=start)))
                h.ingest(t,helper.observation(h,start=returned,end=returned+.1,position=returned-.7,epoch=epoch+1,asset='movie',serial=serial+1,sourceClock=dict(epoch=1,audioRemoved=removed,videoRemoved=removed,updatedAt=returned)))
                self.assertFalse(h.response(t)['transportClockVerified'])
                self.confirm(helper,h,t,offset=offset,serial=serial+2,epoch=epoch+1,start=returned,removed=removed)
                self.assertTrue(h.response(t)['transportClockVerified'])
            self.assertEqual(h.sessions[t]['intercept'],-192.)
    def test_real_33_second_edit_cannot_show_plausible_but_wrong_clock(self):
        with tempfile.TemporaryDirectory() as root:
            helper,h,t=self.fixture(root)
            h.candidates[0]['tracks']['en'] += [dict(index=20+i,start=157.15+i*3,end=159.15+i*3,text='fresh content after cut '+str(i)) for i in range(2)]
            self.enter_and_propose(helper,h,t)
            self.assertAlmostEqual(h.sessions[t]['pendingTransport']['intercept'],-48.)
            self.assertIsNone(h.sessions[t]['reference'])
            self.confirm(helper,h,t,offset=-14.85)
            self.assertAlmostEqual(h.sessions[t]['intercept'],-14.85)
            self.assertTrue(h.response(t)['transportClockVerified'])
            cues=h.response(t)['windows'][-1]['tracks'][0]['cues']
            self.assertAlmostEqual(cues[0]['start'],172.)
            self.assertIn('fresh content',cues[0]['text'])
    def test_fuzzy_cue_prefixes_cannot_confirm_post_ad_clock(self):
        with tempfile.TemporaryDirectory() as root:
            helper,h,t=self.fixture(root);self.enter_and_propose(helper,h,t)
            self.confirm(helper,h,t,fuzzy=True)
            self.assertFalse(h.response(t)['transportClockVerified'])
            self.assertIsNone(h.sessions[t]['reference'])
