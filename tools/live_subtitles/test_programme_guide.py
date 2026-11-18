import time
import tempfile
import unittest
from unittest.mock import patch
from programme_guide import ProgrammeGuide,route_key
from subtitle_cache import SubtitleCache

class GuideTests(unittest.TestCase):
    def test_generic_epg_movie_can_enter_idempotent_resource_cache(self):
        self.rows();self.epg['programmes'][0].update(sourceId='xmltv-reviewed',provenance={});g=ProgrammeGuide()
        with patch('programme_guide.snapshot',side_effect=self.snap),patch('programme_guide.public_read',return_value=b'{"d":[{"id":"tt0000001","qid":"movie","l":"Sunshine Cleaning","y":2008}]}'):
            _,(_,p)=g.resolve(self.source)
        with tempfile.TemporaryDirectory() as d,patch('subtitle_cache.release_year',return_value=2008):
            cache=SubtitleCache(d)
            discover=lambda title,year,root,**kw:[]
            self.assertEqual(cache.get_or_discover(p,d,discover,requested_language='ja'),[])
            self.assertIsNone(p['movieId']);self.assertEqual(p['imdbId'],'tt0000001')

    def rows(self):
        self.source='https://comedy-rakuten-tv-uk.fast.rakuten.tv/v1/manifest/key/production-LiveChannel-6181/old/4.m3u8'
        self.catalog=dict(channels=[dict(id='comedy',routes=[dict(url=self.source)])])
        self.epg=dict(programmes=[dict(channelId='comedy',sourceId='rakuten-uk-official-v1',originalChannelId='rakuten:uk:6181',title='Sunshine Cleaning',startUtc=int(time.time())-30,stopUtc=int(time.time())+900,provenance=dict(movieId='sunshine-cleaning',marketCode='uk',serviceId=6181,sourceEventId='123'))])
    def snap(self,k):return self.catalog if k=='channel-catalog' else self.epg
    def test_verified_delivery_alias_binds_current_movie_and_caches_metadata(self):
        self.rows();g=ProgrammeGuide();new=self.source.replace('manifest','master').replace('LiveChannel-6181','hls-aes128-rtv-6181-playout').replace('/old/4','/master')
        with patch('programme_guide.snapshot',side_effect=self.snap),patch('programme_guide.public_read',return_value=b'{"data":{"id":"sunshine-cleaning","year":2008,"title":"Sunshine Cleaning","imdb_id":"tt0862846"}}') as read:
            c,(_,p)=g.resolve(new,dict(catalogChannelId='comedy'));self.assertEqual(c['id'],'comedy');self.assertEqual(p['imdbId'],'tt0862846');self.assertTrue(p['searchable'])
            self.assertIn(':123:',p['key']);g.current('comedy',new);self.assertEqual(read.call_count,1)
    def test_client_cannot_supply_other_channel_programme_or_private_route(self):
        self.rows();g=ProgrammeGuide()
        with patch('programme_guide.snapshot',side_effect=self.snap):
            for source,context in [(self.source,dict(catalogChannelId='other')),('https://private.invalid/live.m3u8',None)]:
                with self.assertRaises(ValueError):g.resolve(source,context)
    def test_gap_and_overlapping_epg_fail_before_subtitle_lookup(self):
        self.rows();g=ProgrammeGuide()
        with patch('programme_guide.snapshot',side_effect=self.snap),patch('programme_guide.public_read') as read:
            original=list(self.epg['programmes'])
            for rows in [[],original+original]:
                self.epg['programmes']=rows
                with self.assertRaises(ValueError):g.resolve(self.source)
            read.assert_not_called()
    def test_title_ambiguity_does_not_guess_release_year(self):
        self.rows();p=self.epg['programmes'][0];p.update(sourceId='xmltv-reviewed');p['provenance']={};g=ProgrammeGuide()
        with patch('programme_guide.snapshot',side_effect=self.snap),patch('programme_guide.public_read',return_value=b'{"d":[{"id":"tt0000001","qid":"movie","l":"Sunshine Cleaning","y":2008},{"id":"tt0000002","qid":"movie","l":"Sunshine Cleaning","y":2020}]}'):
            _,(_,v)=g.resolve(self.source);self.assertFalse(v['searchable']);self.assertIsNone(v['year'])

if __name__=='__main__':unittest.main()
