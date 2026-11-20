import json
import tempfile
import unittest
from unittest.mock import patch
import subtitle_stremio as adapter
from live_engine import acoustic_norm, align

SRT=b'1\n00:00:01,000 --> 00:00:02,000\nOne\n\n2\n00:00:03,000 --> 00:00:04,000\nTwo\n\n3\n00:00:05,000 --> 00:00:06,000\nThree\n'
class StremioTests(unittest.TestCase):
    def test_exact_imdb_title_year_language_and_persisted_download(self):
        row=dict(lang='eng',movieReleaseName='The.Prince.2014.BluRay',url='https://subs5.strem.io/en/download/subencoding-stremio-utf8/src-api/file/12')
        rows=[row,dict(row,lang='fre'),dict(row,lang='chi'),dict(row,movieReleaseName='The.Prince.2015.BluRay')]
        calls=[]
        def read(url):
            calls.append(url)
            return json.dumps(dict(subtitles=rows)).encode() if url.endswith('.json') else SRT
        with tempfile.TemporaryDirectory() as root,patch.object(adapter,'read',read):
            result=adapter.discover('The Prince',2014,root,imdb_id='tt1085492')
            self.assertEqual(len(result),1);self.assertEqual(set(result[0]['tracks']),{'en','fr'})
            self.assertIn('tt1085492',result[0]['searchUrl'])
            calls.clear();adapter.discover('The Prince',2014,root,imdb_id='tt1085492')
            self.assertEqual(len(calls),1)
    def test_unreviewed_urls_rejected_without_request(self):
        for url in ['http://subs5.strem.io/en/download/subencoding-stremio-utf8/src-api/file/12','https://subs5.strem.io:8443/en/download/subencoding-stremio-utf8/src-api/file/12','https://other.example/subtitles/movie/tt1085492.json']:
            with self.assertRaises(ValueError):adapter.read(url)

    def test_chinese_provider_tag_does_not_override_actual_script(self):
        english = dict(lang='eng',movieReleaseName='Buddy.Cops.WEBRip.Netflix.en',
                       url='https://subs5.strem.io/en/download/subencoding-stremio-utf8/src-api/file/12')
        chinese = dict(english,lang='zht',movieReleaseName='Buddy.Cops.WEBRip.Netflix.zh-Hans.Simplified Chinese',
                       url='https://subs5.strem.io/en/download/subencoding-stremio-utf8/src-api/file/13')
        raw = SRT.decode().replace('One','我们这个时候说我们这个时候说').replace('Two','这样我们会听见这样我们会听见').replace('Three','我发现这是我们的问题我发现这是我们的问题').encode()
        with tempfile.TemporaryDirectory() as root,patch.object(adapter,'read',side_effect=lambda url:
                json.dumps(dict(subtitles=[english,chinese])).encode() if url.endswith('.json')
                else raw if url.endswith('/13') else SRT):
            result=adapter.discover('Buddy Cops',2016,root,imdb_id='tt5617254')
            self.assertEqual(len(result),1)
            self.assertEqual(set(result[0]['tracks']),{'en','zh-CN'})
        self.assertFalse(adapter.matches_bound_release('Buddy Cops 2 WEBRip','Buddy Cops',2016))
    def test_contractions_preserve_actual_first_word_timestamp(self):
        self.assertEqual(acoustic_norm("There's nothing we can't do"),acoustic_norm('There is nothing we can not do'))
        cues=[dict(index=i,start=i*5,end=i*5+3,text=f"There is nothing we can do {i}") for i in range(3)]
        words=[dict(word=w,start=i*5+j*.2,end=i*5+j*.2+.1,probability=.9) for i in range(3) for j,w in enumerate(f"There's nothing we can do {i}".split())]
        offset,anchors=align(words,cues,0)
        self.assertEqual(offset,0);self.assertEqual([a['asrStart'] for a in anchors],[0,5,10])
    def test_confirmed_fps_rate_is_used_for_fresh_acoustic_clustering(self):
        rate=25/24
        cues=[dict(index=i,start=100+rate*(i*15),end=103+rate*(i*15),text=f'{name} signal check now') for i,name in enumerate(['alpha','beta','gamma'])]
        words=[dict(word=word,start=i*15+shift+j*.2,end=i*15+shift+j*.2+.1,probability=.95) for i,(cue,shift) in enumerate(zip(cues,[.3,0,-.3])) for j,word in enumerate(cue['text'].split())]
        self.assertIsNone(align(words,cues,0)[0])
        offset,anchors=align(words,cues,0,rate=rate)
        self.assertAlmostEqual(offset,100);self.assertEqual(len(anchors),3)

    def test_sdh_speakers_and_sound_labels_do_not_become_spoken_anchors(self):
        original=r"{\an8}[door opens] CLAY: They're in the hole."
        self.assertEqual(acoustic_norm(original),acoustic_norm('They are in the hole.'))
        self.assertEqual(acoustic_norm('PIPPIN: Oh my god, I can not get my shoes wet.'),acoustic_norm('Oh my god, I cannot get my shoes wet.'))
        self.assertEqual(acoustic_norm('The clock: it is late.'),acoustic_norm('The clock it is late.'))

    def fuzzy_case(self,ambiguous=False):
        texts=['They are in the hole', 'That is not a lake that is a puddle', 'Oh my god I can not get my shoes wet', 'That is not a good idea']
        if ambiguous:texts.append('That is not a pond that is a puddle')
        starts=[100,120,123,500,600]
        cues=[dict(index=i,start=starts[i],end=starts[i]+3,text=text) for i,text in enumerate(texts)]
        words=[dict(word=w,start=starts[i]-100+j*.1,end=starts[i]-100+j*.1+.1,probability=.95) for i,text in enumerate(texts[:3]) for j,w in enumerate(text.replace('lake','link').split())]
        return cues,words
    def test_one_substituted_word_needs_unique_context_and_other_fresh_cues(self):
        cues,words=self.fuzzy_case();offset,anchors=align(words,cues,0)
        self.assertAlmostEqual(offset,100);self.assertTrue(any(a.get('fuzzyPrefix') for a in anchors))
    def test_near_duplicate_reference_rejects_fuzzy_prefix(self):
        cues,words=self.fuzzy_case(ambiguous=True)
        self.assertIsNone(align(words,cues,0)[0])

    def test_movie_sized_reference_retains_exact_and_unique_fuzzy_onsets(self):
        cues,words=self.fuzzy_case()
        cues += [dict(index=100+i,start=1000+i*3,end=1002+i*3,
                      text=f'padding{i} sequence{i} has a different spoken phrase')
                 for i in range(2000)]
        offset,anchors=align(words,cues,0)
        self.assertAlmostEqual(offset,100)
        self.assertEqual({a['cue'] for a in anchors},{0,1,2})
        self.assertEqual(next(a for a in anchors if a.get('fuzzyPrefix'))['asrStart'],20)

    def test_distant_ambiguous_prefix_still_blocks_a_fuzzy_onset(self):
        cues,words=self.fuzzy_case()
        cues += [dict(index=100+i,start=1000+i*3,end=1002+i*3,
                      text=f'padding{i} sequence{i} has a different spoken phrase')
                 for i in range(2000)]
        cues.append(dict(index=3000,start=9000,end=9003,
                         text='That is not a pond that is a puddle'))
        self.assertIsNone(align(words,cues,0)[0])

if __name__=='__main__':unittest.main()
