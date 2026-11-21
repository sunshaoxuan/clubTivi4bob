import tempfile
import unittest
import json

from subtitle_ai import SubtitleAI
from subtitle_cache import SubtitleCache, verified_release_aliases
from subtitle_stremio import matches_bound_release
from client_clock import TextHub


class SubtitleAITest(unittest.TestCase):
    def english(self):
        return [dict(index=i,start=i*25,end=i*25+2,text='Test input') for i in range(105)]

    def test_rakuten_alias_applies_only_to_official_film(self):
        movie=dict(movieId='iron-fury-aka-t-34',imdbId='tt8820590',
                   identityEvidence='official_movie_record')
        alias,=verified_release_aliases(movie)
        self.assertTrue(matches_bound_release('T-34 2018 BluRay',alias,2018))
        self.assertFalse(matches_bound_release('T-34 2 2018 BluRay',alias,2018))
        self.assertEqual(verified_release_aliases(dict(movie,identityEvidence=None)),())

    def test_review_cannot_select_unoffered_records(self):
        with tempfile.TemporaryDirectory() as root:
            ai=SubtitleAI(root,lambda *_: {'indices':[1]})
            self.assertEqual(ai.review('Film',2018,'tt8820590',['One','Two']),{1})
            self.assertEqual(ai.review('Film',2018,'tt8820590',['One']),set())
            self.assertEqual(ai.review('Film',2018,None,['One','Two']),set())

    def test_full_track_reuses_times_and_cache(self):
        calls=[]
        def transport(_instruction, data):
            calls.append(data)
            return {'rows':[dict(id=c['id'],text='我们正在说话。') for c in data['cues']]}
        with tempfile.TemporaryDirectory() as root:
            ai=SubtitleAI(root,transport)
            english=self.english()
            result=ai.translate('Film',english)
            self.assertEqual(len(result),len(english))
            self.assertEqual([(c['start'],c['end']) for c in result],
                             [(c['start'],c['end']) for c in english])
            self.assertEqual(ai.translate('Film',english),result)
            self.assertEqual(len(calls),2)

    def test_partial_batch_does_not_publish_and_obeys_retry(self):
        calls=[]
        def transport(_instruction, data):
            calls.append(data)
            return {'rows':[dict(id=c['id'],text='我们正在说话。') for c in data['cues'][:-1]]}
        with tempfile.TemporaryDirectory() as root:
            ai=SubtitleAI(root,transport)
            self.assertIsNone(ai.translate('Film',self.english()))
            self.assertIsNone(ai.translate('Film',self.english()))
            self.assertEqual(len(calls),1)

    def test_generated_caption_is_labelled_and_human_chinese_replaces_it(self):
        english=self.english()
        ai=dict(page='a',tracks={'en':english,'zh-CN':english},
                provenance={'zh-CN':dict(generated=True)})
        human=dict(page='b',tracks={'en':english,'zh-TW':english})
        hub=TextHub.__new__(TextHub)
        hub.candidates=[ai]
        session=dict(reference=ai,language='zh-CN',audioLanguage='en',
                     windows=[dict(state='LOCKED',start=0,end=12,
                                   subtitleClock=dict(rate=1,intercept=0))])
        self.assertTrue(hub.caption_tracks(ai,0,12,1,0)[-1]['cues'][0]['text'].startswith('[AI] '))
        hub.candidates=[human]
        hub.refresh_reference_languages(session)
        self.assertIs(session['reference'],human)
        self.assertEqual(hub.preferred_track(human,'zh-CN'),'zh-TW')
        self.assertFalse(session['windows'][0]['tracks'][-1]['cues'][0]['text'].startswith('[AI] '))

    def test_no_generation_with_incomplete_search_or_either_chinese_track(self):
        calls=[]
        movie=dict(title='Iron Fury',year=2018,searchable=True,
                   identityEvidence='official_movie_record',imdbId='tt8820590')
        english=self.english()
        reference=dict(page='a',tracks={'en':english},
                       provenance={'en':dict(imdbId=movie['imdbId'])})
        with tempfile.TemporaryDirectory() as root:
            cache=SubtitleCache(root)
            def transport(_instruction,data):
                calls.append(data)
                return {'rows':[dict(id=c['id'],text='我们正在说话。') for c in data['cues']]}
            cache.ai=SubtitleAI(cache.root/'.ai',transport)
            rows=[reference]
            with cache.locked(cache.identity(movie)) as folder:
                receipt=folder/'index.json'
                state=dict(providerOutcomes=[dict(outcome='no_matching_release')],
                           searches={'zh-CN':dict(outcome='not_found_this_search'),
                                     'zh-TW':dict(outcome='timing_pending')})
                receipt.write_text(json.dumps(state))
            self.assertIs(cache.with_ai_chinese(movie,rows,'zh-CN'),rows)
            self.assertEqual(calls,[])
            state['searches']['zh-TW']['outcome']='not_found_this_search'
            receipt.write_text(json.dumps(state))
            existing=[dict(reference,tracks={'en':english,'zh-TW':english})]
            self.assertIs(cache.with_ai_chinese(movie,existing,'zh-CN'),existing)
            self.assertEqual(calls,[])
            result=cache.with_ai_chinese(movie,rows,'zh-TW')
            self.assertTrue(result[0]['provenance']['zh-CN']['generated'])
            self.assertEqual(len(calls),2)
