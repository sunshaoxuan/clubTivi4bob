import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from live_media import parse_media, playlist
from live_engine import Engine, align
from service import Hub, CHANNEL
from subtitle_catalog import discover, parse_srt


class LiveServiceTests(unittest.TestCase):
    def test_movie_caid_on_an_insert_does_not_become_episode_identity(self):
        raw = '#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:10\n#EXT-X-ASSET:CAID="m_9"\n#EXTINF:1.0,\nad.ts\n#EXTINF:6.0,extke=Rakutentv:epid=film:ct=m:vt=s\nfilm.ts\n'
        rows = parse_media(raw, 'https://example.org/live')
        self.assertEqual(rows[0]['caid'], 'm_9')
        self.assertIsNone(rows[0]['contentId'])
        self.assertEqual(rows[1]['contentId'], 'film')

    def test_subtitle_search_excludes_same_year_tv_episode_with_title_words(self):
        search = '<a href="/subs/1/tv.html">Two and a Half Men 2003 S06 A Jock Strap in Hell</a><a href="/subs/2/film.html">In Hell 2003 BluRay</a>'
        detail = '<a id="download_en" href="/subs/2/a.srt">Download</a><button onclick="generate()">Translate</button>'
        srt = b'1\n00:00:01,000 --> 00:00:02,000\nOne\n\n2\n00:00:03,000 --> 00:00:04,000\nTwo\n\n3\n00:00:05,000 --> 00:00:06,000\nThree\n'
        calls = []
        def read(url):
            calls.append(url)
            return search.encode() if 'index.php?' in url else detail.encode() if url.endswith('.html') else srt
        with tempfile.TemporaryDirectory() as root, patch('subtitle_catalog.read', read):
            result = discover('In Hell', 2003, root)
        self.assertEqual(len(result), 1)
        self.assertEqual(set(result[0]['tracks']), {'en'})
        self.assertFalse(any('tv.html' in url or 'generate' in url for url in calls))

    def test_alignment_requires_multiple_distinct_cues_and_temporal_span(self):
        cues = [dict(index=i+1,start=100+i*5,end=104+i*5,text=text) for i,text in enumerate([
            'bring the heavy wooden chair inside', 'we must leave before the morning comes', 'another traveler waits beneath the bridge'])]
        words = [dict(word=word,start=i*5+j*.25,end=i*5+j*.25+.2,probability=.99)
                 for i,cue in enumerate(cues) for j,word in enumerate(cue['text'].split())]
        offset, anchors = align(words,cues,0)
        self.assertAlmostEqual(offset,100)
        self.assertEqual(len({x['cue'] for x in anchors}),3)
        self.assertIsNone(align(words[:6],cues,0)[0])

    def test_published_english_original_requires_matching_same_page_grid(self):
        search = '<tr><td><a href="/subs/2/film.html">In Hell 2003</a> (translated from English)</td></tr>'
        detail = '<a id="download_es" href="/subs/2/es.srt">Download</a><h3>Original subtitles</h3>' + ''.join('<p dir="auto">'+s+'</p>' for s in ['One','Two','Three']) + '</div>'
        srt = b'1\n00:00:01,000 --> 00:00:02,000\nUno\n\n2\n00:00:03,000 --> 00:00:04,000\nDos\n\n3\n00:00:05,000 --> 00:00:06,000\nTres\n'
        def read(url):
            return search.encode() if 'index.php?' in url else detail.encode() if url.endswith('.html') else srt
        with tempfile.TemporaryDirectory() as root,patch('subtitle_catalog.read',read):
            result=discover('In Hell',2003,root)
        self.assertEqual([c['text'] for c in result[0]['tracks']['en']],['One','Two','Three'])
        self.assertEqual(result[0]['provenance']['en']['clockGridLanguage'],'es')
        detail=detail.replace('<p dir="auto">Three</p>','')
        with tempfile.TemporaryDirectory() as root,patch('subtitle_catalog.read',read):
            self.assertEqual(discover('In Hell',2003,root),[])

    def test_session_requires_current_exact_route_and_programme(self):
        hub = Hub.__new__(Hub); hub.source='https://public.example/route'; hub.gap=False
        hub.last_guide_success=time.time(); hub.programme=dict(key='current',stopUtc=time.time()+3600)
        self.assertTrue(hub.valid_context(hub.source,dict(key='current',catalogChannelId=CHANNEL)))
        self.assertFalse(hub.valid_context('https://private.example/route',None))
        self.assertFalse(hub.valid_context(hub.source,dict(key='previous',catalogChannelId=CHANNEL)))
        hub.last_guide_success-=121
        self.assertFalse(hub.valid_context(hub.source,None))

    def test_ad_clears_cues_and_return_requires_verified_pts_continuity(self):
        for return_pts,expected in [(12.,'LOCKED'),(300.,'ACQUIRING')]:
            with self.subTest(return_pts=return_pts),tempfile.TemporaryDirectory() as root:
                candidate=dict(page='existing-file',tracks={'en':[dict(index=1,start=100,end=150,text='Existing subtitle')]})
                e=Engine('https://public.example/route',dict(movieId='film',title='Film',year=2003),root,None,'ffmpeg',candidates=[candidate])
                e.collector.rows=[dict(sequence=i,duration=duration,timelineStart=start,timelineEnd=start+duration,
                    contentId=content,caid='m_9',sequenceGap=False,asset='film-asset' if content else 'insert-asset',observedWall=time.time())
                    for i,start,duration,content in [(1,0,6,'film'),(2,6,6,'film'),(3,12,2,None),(4,14,6,'film')]]
                def transcribe(*args):
                    e.collector.stop.set()
                    return []
                with patch('live_engine.media_pts',lambda row,*_: {1:0.,2:6.,4:return_pts}[row['sequence']]),patch('live_engine.transcribe',transcribe),patch('live_engine.align',lambda *args:(100.,[dict(cue=1)])):
                    e.run()
                self.assertEqual(e.decisions[3]['state'],'SUSPENDED')
                self.assertEqual(e.decisions[3]['tracks'],[])
                self.assertEqual(e.decisions[4]['state'],expected)
                if expected!='LOCKED': self.assertEqual(e.decisions[4]['tracks'],[])


if __name__=='__main__':
    unittest.main()
