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

if __name__=='__main__':unittest.main()
