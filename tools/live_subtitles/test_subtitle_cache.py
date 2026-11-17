import concurrent.futures
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from subtitle_cache import SubtitleCache, movie_aliases, srt_bytes, NEGATIVE_TTL
from subtitle_catalog import LANGUAGES


def candidate(languages=LANGUAGES):
    return dict(page='https://www.subtitlecat.com/subs/1/film.html', label='Film 2003',
        tracks={lang:[dict(index=i+1,start=float(i*2),end=float(i*2+1),text=f'{lang} line {i}') for i in range(3)] for lang in languages},
        provenance={lang:dict(provider='existing file',url=f'https://www.subtitlecat.com/film.{lang}.srt') for lang in languages})


class SubtitleCacheTests(unittest.TestCase):
    def setUp(self):
        stub=patch('subtitle_cache.release_year',return_value=None);stub.start();self.addCleanup(stub.stop)

    film=dict(movieId='film',marketCode='uk',title='Film',year=2003,imdbId='tt1234567')

    def test_imdb_release_year_retries_a_prior_negative_without_changing_epg_year(self):
        with tempfile.TemporaryDirectory() as directory:
            cache=SubtitleCache(Path(directory)/'cache');film=dict(self.film,year=2004);calls=[]
            def find(title,year,*args,**kwargs):
                calls.append(year)
                return [candidate()] if year==2003 else []
            self.assertEqual(cache.get_or_discover(film,Path(directory)/'download',find),[])
            with patch('subtitle_cache.release_year',return_value=2003):
                self.assertTrue(cache.get_or_discover(film,Path(directory)/'download',find))
                self.assertTrue(cache.get_or_discover(film,Path(directory)/'download',find))
            self.assertEqual(calls,[2004,2003])
            index=json.loads(next((Path(directory)/'cache').glob('*/index.json')).read_text())
            self.assertEqual(index['year'],2004);self.assertEqual(index['subtitleYear'],2003)
            self.assertEqual(film['year'],2004)

    def test_all_seven_languages_survive_a_new_cache_instance_without_network(self):
        with tempfile.TemporaryDirectory() as directory:
            cache=SubtitleCache(Path(directory)/'cache');calls=[]
            def find(*args,**kwargs):calls.append(kwargs['requested_language']);return [candidate()]
            cache.get_or_discover(self.film,Path(directory)/'download',find,requested_language='ja')
            restarted=SubtitleCache(Path(directory)/'cache')
            for lang in LANGUAGES:
                rows=restarted.get_or_discover(self.film,Path(directory)/'download',find,requested_language=lang)
                self.assertIn(lang,rows[0]['tracks']);self.assertTrue(rows[0]['cacheHit'])
            self.assertEqual(calls,['ja'])
            index=json.loads(next((Path(directory)/'cache').glob('*/index.json')).read_text())
            self.assertEqual(set(index['editions'][0]['tracks']),set(LANGUAGES))
            self.assertIn('imdb:tt1234567',index['identity'])

    def test_old_provider_manifest_is_refreshed_once_and_keeps_valid_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            cache=SubtitleCache(Path(directory)/'cache');root=Path(directory)/'download'
            cache.get_or_discover(self.film,root,lambda *a,**k:[candidate()])
            index=next((Path(directory)/'cache').glob('*/index.json'))
            manifest=json.loads(index.read_text());manifest['resourceSchemaVersion']=1
            index.write_text(json.dumps(manifest));calls=[]
            def refresh(*args,**kwargs):calls.append(1);return []
            self.assertTrue(cache.get_or_discover(self.film,root,refresh))
            self.assertTrue(cache.get_or_discover(self.film,root,refresh))
            self.assertEqual(calls,[1])

    def test_promoting_verified_imdb_preserves_official_identity_and_rejects_conflicts(self):
        with tempfile.TemporaryDirectory() as directory:
            cache=SubtitleCache(directory)
            old={**self.film,'imdbId':None};key=cache.identity(old)
            self.assertEqual(cache.identity(self.film),key)
            self.assertEqual(cache.identity({**self.film,'movieId':None}),key)
            other={**self.film,'movieId':'another-film','imdbId':'tt7654321'}
            self.assertNotEqual(cache.identity(other),key)
            with self.assertRaisesRegex(ValueError,'conflicting_movie_identity'):
                cache.identity({**self.film,'imdbId':'tt7654321'})
            self.assertNotEqual(movie_aliases(dict(title='Film',year=2003)),movie_aliases(dict(title='Film',year=2023)))
            self.assertNotEqual(movie_aliases(dict(title='英雄',year=2003)),movie_aliases(dict(title='无间道',year=2003)))

    def test_unpaired_language_resources_survive_restart_without_redownload(self):
        from subtitle_catalog import save_resource,load_resource
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory);now=[1000.];cache=SubtitleCache(base/'cache',clock=lambda:now[0])
            url='https://dl.subdl.com/subtitle/1-2.zip';downloads=[]
            raw=srt_bytes(candidate(['ja'])['tracks']['ja'])
            def find(title,year,root,**kwargs):
                Path(root).mkdir(parents=True,exist_ok=True)
                if not load_resource(root,url,'ja'):
                    downloads.append(1);save_resource(root,url,'ja','Film 2003',raw,'SubDL')
                return [candidate(['en'])]
            rows=cache.get_or_discover(self.film,base/'first',find,requested_language='ja')
            self.assertNotIn('ja',rows[0]['tracks'])
            index=json.loads(next((base/'cache').glob('*/index.json')).read_text())
            self.assertEqual(index['resources'][0]['language'],'ja')
            self.assertFalse(index['resources'][0]['pairedWithEnglish'])
            now[0]+=NEGATIVE_TTL+1
            restarted=SubtitleCache(base/'cache',clock=lambda:now[0])
            restarted.get_or_discover(self.film,base/'second',find,requested_language='ja')
            self.assertEqual(downloads,[1]);self.assertIsNotNone(load_resource(base/'second',url,'ja'))

    def test_cached_title_prefix_collision_cannot_reuse_another_movie(self):
        with tempfile.TemporaryDirectory() as directory:
            cache=SubtitleCache(directory)
            film=dict(movieId='the-prince',marketCode='uk',title='The Prince',year=2014,imdbId='tt1085492')
            wrong={**candidate(['en']), 'label':'The.Prince.and.the.108.Demons.2014.720p.WEBRip.x264'}
            folder=Path(directory)/cache.identity(film)
            with cache.locked(cache.identity(film)):
                cache.store(folder,film,[wrong],directory)
            calls=[]
            correct={**candidate(), 'label':'The.Prince.2014.BluRay'}
            def find(*a,**kw):calls.append(1);return [correct]
            rows=cache.get_or_discover(film,directory,find,requested_language='ja')
            self.assertEqual(calls,[1]);self.assertEqual([c['label'] for c in rows],['The.Prince.2014.BluRay'])

    def test_single_flight_per_movie_across_concurrent_viewers(self):
        with tempfile.TemporaryDirectory() as directory:
            calls=[]
            def find(*args,**kwargs):calls.append(1);time.sleep(.04);return [candidate()]
            def viewer(_):return SubtitleCache(directory).get_or_discover(self.film,directory,find)
            with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:rows=list(pool.map(viewer,range(6)))
            self.assertEqual(len(calls),1);self.assertTrue(all(rows))

    def test_corrupt_language_blob_is_downloaded_again_without_losing_other_languages(self):
        with tempfile.TemporaryDirectory() as directory:
            cache=SubtitleCache(directory);calls=[]
            def find(*args,**kwargs):calls.append(1);return [candidate()]
            cache.get_or_discover(self.film,directory,find)
            index=json.loads(next(Path(directory).glob('*/index.json')).read_text())
            sha=index['editions'][0]['tracks']['ja']['sha256']
            (Path(directory)/'blobs'/(sha+'.srt')).write_bytes(b'corrupt')
            rows=cache.get_or_discover(self.film,directory,find,requested_language='ja')
            self.assertEqual(len(calls),2);self.assertEqual(set(rows[0]['tracks']),set(LANGUAGES))

    def test_negative_result_expires_and_does_not_become_a_permanent_miss(self):
        with tempfile.TemporaryDirectory() as directory:
            now=[1000.];cache=SubtitleCache(directory,clock=lambda:now[0]);calls=[]
            def find(*args,**kwargs):calls.append(1);return []
            for _ in range(2):self.assertEqual(cache.get_or_discover(self.film,directory,find),[])
            self.assertEqual(len(calls),1);now[0]+=NEGATIVE_TTL+1
            cache.get_or_discover(self.film,directory,find);self.assertEqual(len(calls),2)

    def test_existing_downloads_are_imported_only_with_matching_observed_movie(self):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory);private=base/'private/session/subtitles';private.mkdir(parents=True)
            rows=[candidate()]
            (private/'discovery.json').write_text(json.dumps(rows))
            (private.parent/'decisions.jsonl').write_text(json.dumps(dict(program='wrong-film'))+'\n')
            cache=SubtitleCache(base/'cache',legacy_roots=[base/'private'])
            calls=[]
            def search(*a,**k):calls.append(1);return rows
            cache.get_or_discover(self.film,base/'downloads',search)
            self.assertEqual(calls,[1])
            (private.parent/'decisions.jsonl').write_text(json.dumps(dict(program='film'))+'\n')
            rows[0]['label']='Film 2003';(private/'discovery.json').write_text(json.dumps(rows))
            cache2=SubtitleCache(base/'cache2',legacy_roots=[base/'private'])
            def forbidden(*a,**k):raise AssertionError('provider must not be contacted')
            restored=cache2.get_or_discover(self.film,base/'downloads',forbidden)
            self.assertEqual(set(restored[0]['tracks']),set(LANGUAGES));self.assertTrue(restored[0]['cacheHit'])

    def test_provider_failure_keeps_cached_english_and_retries_are_coalesced(self):
        with tempfile.TemporaryDirectory() as directory:
            now=[1000.];cache=SubtitleCache(directory,clock=lambda:now[0])
            cache.get_or_discover(self.film,directory,lambda *a,**k:[candidate(['en'])])
            now[0]+=NEGATIVE_TTL+1;calls=[]
            def unavailable(*a,**k):calls.append(1);raise OSError('provider offline')
            for _ in range(3):
                rows=cache.get_or_discover(self.film,directory,unavailable,requested_language='ja')
                self.assertIn('en',rows[0]['tracks'])
            self.assertEqual(len(calls),1)
            now[0]+=61
            cache.get_or_discover(self.film,directory,unavailable,requested_language='ja')
            self.assertEqual(len(calls),2)

    def test_live_offsets_and_session_state_are_never_reused_from_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            cache=SubtitleCache(directory)
            row={**candidate(), 'offset':128.5, 'session':'old-session', 'adCalibration':{'delta':30}}
            cache.get_or_discover(self.film,directory,lambda *a,**k:[row])
            loaded,_=cache.load(Path(directory)/cache.identity(self.film))
            self.assertNotIn('offset',loaded[0]);self.assertNotIn('session',loaded[0])
            self.assertNotIn('adCalibration',loaded[0])
            self.assertEqual(set(loaded[0]['tracks']),set(LANGUAGES))

    def test_editions_and_language_grids_are_not_combined(self):
        with tempfile.TemporaryDirectory() as directory:
            cache=SubtitleCache(directory);first=candidate(['en','ja']);second=candidate(['en','fr'])
            second['page']='https://www.subtitlecat.com/subs/2/different-cut.html'
            for cue in second['tracks']['en']:cue['start']+=10;cue['end']+=10
            rows=cache.get_or_discover(self.film,directory,lambda *a,**k:[first,second])
            folder=Path(directory)/cache.identity(self.film);loaded,_=cache.load(folder)
            self.assertEqual(len(loaded),2)
            self.assertNotIn('ja',loaded[1]['tracks']);self.assertNotIn('fr',loaded[1]['tracks'])

if __name__=='__main__':unittest.main()
