import concurrent.futures
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from subtitle_cache import SubtitleCache, movie_aliases, srt_bytes, NEGATIVE_TTL
from subtitle_catalog import LANGUAGES


def candidate(languages=LANGUAGES):
    return dict(page='https://www.subtitlecat.com/subs/1/film.html', label='Film 2003',
        tracks={lang:[dict(index=i+1,start=float(i*2),end=float(i*2+1),text=f'{lang} line {i}') for i in range(3)] for lang in languages},
        provenance={lang:dict(provider='existing file',url=f'https://www.subtitlecat.com/film.{lang}.srt') for lang in languages})


class SubtitleCacheTests(unittest.TestCase):
    film=dict(movieId='film',marketCode='uk',title='Film',year=2003,imdbId='tt1234567')

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
