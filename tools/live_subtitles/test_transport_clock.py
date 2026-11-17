import time,tempfile,unittest
from unittest.mock import patch
from transport_clock import clock,project
import test_client_clock

class TransportClockTests(unittest.TestCase):
    def model(self):
        return dict(asset='movie',programme='programme',epoch=1,rate=1.,intercept=100.,verifiedAt=time.time(),clock=dict(epoch=1,audioRemoved=0.,videoRemoved=0.,updatedAt=0.))
    def proposal(self,model=None,current=None,**changes):
        args=dict(asset='movie',programme='programme',epoch=3,start=170.,position=169.3,ad_start=20.,now=time.time());args.update(changes)
        return project(model or self.model(),current or dict(epoch=1,audioRemoved=-148.053333,videoRemoved=-147.925033,updatedAt=170.),**args)
    def test_captured_two_second_content_jump_is_not_ad_duration_subtraction(self):
        result=self.proposal()
        self.assertAlmostEqual(result['sourceMovieAdvanceSeconds'],2.010817,places=6)
        self.assertAlmostEqual(result['intercept'],-47.989183,places=6)
        self.assertGreaterEqual(result['start'],171.)
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
    def test_ad_suspends_then_fresh_clock_resumes_without_waiting_for_speech(self):
        with tempfile.TemporaryDirectory() as root:
            helper,h,t=self.fixture(root)
            h.ingest(t,helper.observation(h,start=20,end=20.1,epoch=2,asset='ad',ad=True,sourceClock=dict(epoch=1,audioRemoved=9000,videoRemoved=9000,updatedAt=20)))
            self.assertFalse(h.response(t)['transportClockVerified'])
            h.ingest(t,helper.observation(h,start=170,end=170.1,position=169.3,epoch=3,asset='movie',serial=2,sourceClock=dict(epoch=1,audioRemoved=-148,videoRemoved=-148,updatedAt=170)))
            result=h.response(t);self.assertTrue(result['transportClockVerified'])
            self.assertEqual(result['windows'][-1]['start'],171)
            self.assertEqual(h.sessions[t]['intercept'],-48)
    def test_successive_ads_use_each_new_boundary_and_measured_content_jump(self):
        with tempfile.TemporaryDirectory() as root:
            helper,h,t=self.fixture(root)
            for serial,start,returned,removed in [(1,20.,170.,-148.),(3,300.,450.,-292.)]:
                h.ingest(t,helper.observation(h,start=start,end=start+.1,epoch=serial+1,asset='ad',ad=True,serial=serial))
                h.ingest(t,helper.observation(h,start=returned,end=returned+.1,position=returned-.7,epoch=serial+2,asset='movie',serial=serial+1,sourceClock=dict(epoch=1,audioRemoved=removed,videoRemoved=removed,updatedAt=returned)))
                self.assertTrue(h.response(t)['transportClockVerified'])
            self.assertEqual(h.sessions[t]['intercept'],-192.)

    def test_new_acoustic_contradiction_stops_transport_forecast(self):
        with tempfile.TemporaryDirectory() as root:
            helper,h,t=self.fixture(root)
            h.ingest(t,helper.observation(h,start=20,end=20.1,epoch=2,asset='ad',ad=True))
            data=helper.observation(h,start=170,end=190,position=189,epoch=3,asset='movie',serial=2,sourceClock=dict(epoch=1,audioRemoved=-148,videoRemoved=-148,updatedAt=170),words=[dict(word='clear speech',start=1,end=2,probability=.9)])
            anchors=[dict(cue=i,asrStart=170+i*3,subtitleStart=124+i*3,offset=-46.,words=9) for i in (1,2,3)]
            with patch('client_clock.align',return_value=(-46.,anchors)):h.ingest(t,data)
            self.assertFalse(h.response(t)['transportClockVerified']);self.assertIsNone(h.sessions[t].get('sourceModel'))
