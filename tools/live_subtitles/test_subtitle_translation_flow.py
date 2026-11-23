import tempfile
import threading
import time
import unittest
from pathlib import Path

from client_clock import TextHub
from subtitle_cache import SubtitleCache
from subtitle_ai import SubtitleAI


class TranslationFlowTests(unittest.TestCase):
    def hub(self, root, transport):
        from test_client_clock import ClientClockTests
        hub=ClientClockTests().hub(root)
        hub.discovery_generation=0
        hub.resource_identity=dict(title='Film',year=2018,searchable=True,
            imdbId='tt8820590',identityEvidence='official_movie_record')
        hub.resource_identity_programme=hub.programme['key']
        hub.cache=SubtitleCache(Path(root)/'cache')
        hub.cache.ai=SubtitleAI(hub.cache.root/'.ai',transport)
        hub.candidates[0]['provenance']={'en':dict(imdbId='tt8820590',provider='SubDL')}
        token=hub.create(hub.source,None,'ja',['clientClockV1'])
        session=hub.sessions[token]
        session.update(reference=hub.candidates[0],audioLanguage='en',rate=1,intercept=100,
                       asset='movie',epoch=1,rateVerified=True)
        hub.clock_window(session,session['reference'],0,60,1,100)
        return hub,token

    def wait(self, condition):
        deadline=time.monotonic()+4
        while time.monotonic()<deadline:
            if condition():return
            time.sleep(.01)
        self.fail('translation worker did not reach expected state')

    def test_translation_is_background_and_late_old_language_cannot_change_selection(self):
        entered=threading.Event();release=threading.Event()
        def transport(instruction,data):
            if data['targetLanguage']=='ja':entered.set();release.wait(3)
            text='私たちは駅に向かいます。' if data['targetLanguage']=='ja' else '우리는 역으로 가요.'
            return {'rows':[dict(id=c['id'],text=text) for c in data['cues']]}
        with tempfile.TemporaryDirectory() as root:
            hub,token=self.hub(root,transport)
            started=time.monotonic();response=hub.response(token)
            self.assertLess(time.monotonic()-started,.2)
            self.assertEqual(response['subtitleStatus']['translation']['language'],'ja')
            self.assertTrue(entered.wait(1))
            hub.set_language(token,'ko');hub.response(token)
            self.wait(lambda: any('ko' in row['tracks'] for row in hub.candidates))
            release.set()
            self.wait(lambda: all(not job['running'] for job in hub.translation_jobs.values()))
            response=hub.response(token)
            self.assertEqual(hub.sessions[token]['language'],'ko')
            self.assertTrue(any(c['language']=='ko' and c['generated'] for c in response['subtitleStatus']['variantCandidates']))
            self.assertEqual(hub.sessions[token]['reference']['tracks']['ko'][0]['text'],'우리는 역으로 가요.')
            self.assertTrue(hub.sessions[token]['windows'][0]['tracks'][-1]['cues'][0]['text'].startswith('[AI] '))

    def test_programme_change_does_not_publish_old_translation(self):
        entered=threading.Event();release=threading.Event()
        def transport(instruction,data):
            entered.set();release.wait(3)
            return {'rows':[dict(id=c['id'],text='私たちは駅に向かいます。') for c in data['cues']]}
        with tempfile.TemporaryDirectory() as root:
            hub,token=self.hub(root,transport);hub.response(token)
            self.assertTrue(entered.wait(1))
            hub.discovery_generation+=1;hub.programme['key']='new-film';release.set()
            self.wait(lambda: all(not job['running'] for job in hub.translation_jobs.values()))
            self.assertNotIn('ja',hub.candidates[0]['tracks'])

    def test_native_exact_arriving_during_translation_is_never_overwritten(self):
        entered=threading.Event();release=threading.Event()
        def transport(instruction,data):
            entered.set();release.wait(3)
            return {'rows':[dict(id=c['id'],text='私たちは駅に向かいます。') for c in data['cues']]}
        with tempfile.TemporaryDirectory() as root:
            hub,token=self.hub(root,transport);hub.response(token)
            self.assertTrue(entered.wait(1))
            old=hub.candidates[0]
            native={**old,'tracks':{**old['tracks'],'ja':[{**c,'text':'本物の字幕です。'} for c in old['tracks']['en']]}}
            hub.candidates=[native];release.set()
            self.wait(lambda: all(not job['running'] for job in hub.translation_jobs.values()))
            self.assertEqual(hub.candidates[0]['tracks']['ja'][0]['text'],'本物の字幕です。')
            self.assertFalse(hub.ai_track(hub.candidates[0],'ja'))

    def test_refresh_keeps_only_translations_of_the_same_english_reference(self):
        english=[dict(index=1,start=1,end=2,text='Hello')]
        old=dict(page='a',tracks={'en':english,'ja':english},provenance={'ja':{'generated':True}})
        fresh=dict(page='a',tracks={'en':english})
        self.assertIn('ja',TextHub.preserve_generated([old],[fresh])[0]['tracks'])
        other=dict(page='a',tracks={'en':[{**english[0],'text':'Different dialogue'}]})
        self.assertNotIn('ja',TextHub.preserve_generated([old],[other])[0]['tracks'])

    def test_suspension_retains_last_good_priority_and_pinned_partial_can_resume(self):
        from subtitle_variants import SubtitleVariants
        from subtitle_edition import track_fingerprint
        with tempfile.TemporaryDirectory() as root:
            hub,token=self.hub(root,lambda *_: None);session=hub.sessions[token]
            ref=session['reference'];english=ref['tracks']['en']
            ref['tracks']['ja']=[{**english[0],'text':'私たちです。'}]
            ref['provenance']['ja']=dict(generated=True,partial=True,pipeline=3,referenceFingerprint=track_fingerprint(english))
            session['variantId']=SubtitleVariants([ref]).track(ref,'ja')['id']
            entered=threading.Event();release=threading.Event();values=[]
            def translate(*args,**kwargs):
                values.append(kwargs['priority_time']());entered.set();release.wait(2)
                values.append(kwargs['priority_time']());return []
            hub.cache.with_ai_translation=translate
            self.assertIsNotNone(hub.ensure_translation(session));self.assertTrue(entered.wait(1))
            session.update(ad=True,reference=None,intercept=None);release.set()
            self.wait(lambda: all(not job['running'] for job in hub.translation_jobs.values()))
            self.assertEqual(values,[100,100])
