import time
import hashlib
import json
import threading
import tempfile
import unittest
from unittest.mock import patch
from programme_guide import ProgrammeGuide,route_key,film_alias,film_search_title
from multi_client_clock import MultiTextHub
from subtitle_cache import SubtitleCache

class GuideTests(unittest.TestCase):
    def test_reviewed_localized_alias_requires_fresh_matching_movie_metadata(self):
        movie=dict(id='tt15341102',l='Ye wang',qid='movie',y=2020)
        with patch('programme_guide.public_read',return_value=json.dumps(dict(d=[movie])).encode()):
            found=film_alias('野王')
            self.assertEqual(found['imdbId'],'tt15341102')
            self.assertEqual(found['title'],'Ye wang')
            self.assertIsNone(film_alias('野王',2013))
            self.assertIsNone(film_alias('野王',imdb_id='tt0000000'))
        for altered in [dict(movie,qid='tvSeries'),dict(movie,y=2013),dict(movie,l='Other film')]:
            with patch('programme_guide.public_read',return_value=json.dumps(dict(d=[altered])).encode()):
                self.assertIsNone(film_alias('野王'))

    def test_broadcast_part_markers_do_not_change_film_identity(self):
        self.assertEqual(film_search_title('第五元素(下)'), '第五元素')
        self.assertEqual(film_search_title('第五元素（上部）'), '第五元素')
        self.assertEqual(film_search_title('赤壁2：决战天下'), '赤壁2：决战天下')
        self.assertEqual(film_search_title('Kill Bill: Volume 2'), 'Kill Bill: Volume 2')

    def test_current_player_epg_reaches_subtitle_discovery_without_mutating_public_guide(self):
        self.rows()
        source = 'https://example.org/cctv6.m3u8'
        channel = 'cctv6'
        self.catalog['channels'].append(dict(id=channel, routes=[dict(url=source)]))
        title = '刑警兄弟'
        start = int(time.time()) - 120
        stop = start + 3600
        material = json.dumps([channel,title,start,stop], ensure_ascii=False, separators=(',', ':'))
        context = dict(contextKind='player-epg-v1', catalogChannelId=channel,
                       title=title, startUtc=start, stopUtc=stop,
                       key='player-epg:' + hashlib.sha256(material.encode()).hexdigest())
        calls = []
        found = threading.Event()
        class Cache:
            def get_or_discover(self, programme, *args, **kw):
                calls.append(programme)
                if programme.get('imdbId') == 'tt5617254':
                    found.set()
                return []
        movie = dict(title='Buddy Cops',year=2016,imdbId='tt5617254')
        with tempfile.TemporaryDirectory() as root, \
                patch('programme_guide.snapshot',side_effect=self.snap), \
                patch('programme_guide.film_alias',return_value=movie) as identity, \
                patch('programme_guide.public_read',return_value=b'{"data":{"id":"sunshine-cleaning","year":2008,"title":"Sunshine Cleaning","imdb_id":"tt0862846"}}'):
            hub = MultiTextHub(root, Cache(), maintenance=False)
            try:
                existing = hub.create(self.source,None,'en',['clientClockV1'])
                token = hub.create(source,{**context,'imdbId':'tt0000000'},'zh-CN',['clientClockV1'])
                self.assertTrue(found.wait(2))
                identity.assert_called_with(title)
                candidate = next(p for p in calls if p['imdbId'] == 'tt5617254')
                self.assertEqual(candidate['title'],'Buddy Cops')
                self.assertEqual(candidate['year'],2016)
                self.assertTrue(hub.valid_context(source, context, token=token))
                self.assertFalse(hub.valid_context(self.source, context, token=token))
                self.assertFalse(hub.valid_context(source,{**context,'key':'other'},token=token))
                self.assertEqual(hub.owner(existing).programme['imdbId'],'tt0862846')
                self.assertIsNone(hub.owner(token).programme['imdbId'])
                self.assertFalse(hub.owner(token).programme['clockIsSubtitleOffset'])
                for route, hint in [('https://private.invalid/live', context),
                                    (source, {**context, 'title': 'Changed'}),
                                    (source, {**context, 'stopUtc': start + 1})]:
                    with self.assertRaises(ValueError):
                        hub.create(route,hint,'en',['clientClockV1'])
            finally:
                hub.close()

    def test_localized_title_and_english_title_resolve_same_film_but_ambiguity_fails(self):
        def film(imdb):
            def claim(value):return {'mainsnak':{'datavalue':{'value':value}}}
            return {'labels':{'zh':{'value':'刑警兄弟'},'en':{'value':'Buddy Cops'}},
                    'claims':{'P31':[claim({'id':'Q11424'})], 'P345':[claim(imdb)],
                              'P577':[claim({'time':'+2016-01-01T00:00:00Z'})]}}
        for title in ('刑警兄弟','Buddy Cops'):
            with patch('programme_guide.wikidata_read',side_effect=[
                    {'search':[{'id':'Q1'}]},{'entities':{'Q1':film('tt5617254')}}]):
                self.assertEqual(film_alias(title),dict(title='Buddy Cops',year=2016,imdbId='tt5617254'))
        with patch('programme_guide.wikidata_read',side_effect=[
                {'search':[{'id':'Q1'},{'id':'Q2'}]},
                {'entities':{'Q1':film('tt5617254'),'Q2':film('tt5617255')}}]):
            self.assertIsNone(film_alias('刑警兄弟'))

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
    def test_repeated_observations_do_not_rescan_all_catalogue_routes(self):
        import programme_guide
        self.rows();self.catalog['channels'] += [dict(id='channel'+str(i),routes=[dict(url='https://example.invalid/'+str(i)+'.m3u8')]) for i in range(9000)]
        g=ProgrammeGuide()
        with patch('programme_guide.snapshot',side_effect=self.snap),patch('programme_guide.route_key',wraps=programme_guide.route_key) as lookup:
            self.assertEqual(g.channel(self.source)['id'],'comedy');initial=lookup.call_count
            for _ in range(30):self.assertEqual(g.channel(self.source)['id'],'comedy')
            self.assertLessEqual(lookup.call_count-initial,30)
            replacement=dict(channels=[dict(id='other',routes=[dict(url=self.source)]),dict(id='duplicate',routes=[dict(url=self.source)])])
            g.catalog=replacement
            with self.assertRaisesRegex(ValueError,'unbound_public_route'):g.channel(self.source)

    def test_title_ambiguity_does_not_guess_release_year(self):
        self.rows();p=self.epg['programmes'][0];p.update(sourceId='xmltv-reviewed');p['provenance']={};g=ProgrammeGuide()
        with patch('programme_guide.snapshot',side_effect=self.snap),patch('programme_guide.public_read',return_value=b'{"d":[{"id":"tt0000001","qid":"movie","l":"Sunshine Cleaning","y":2008},{"id":"tt0000002","qid":"movie","l":"Sunshine Cleaning","y":2020}]}'):
            _,(_,v)=g.resolve(self.source);self.assertFalse(v['searchable']);self.assertIsNone(v['year'])

if __name__=='__main__':unittest.main()
