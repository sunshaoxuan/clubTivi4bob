import tempfile
import unittest
from unittest.mock import patch
from subtitle_identity import resolve, release_year

class IdentityTests(unittest.TestCase):
    film=dict(title='The Prince',year=2014,movieId='the-prince')
    exact=dict(id='tt1085492',l='The Prince',y=2014,qid='movie')
    def test_exact_title_year_and_type_with_persistent_warm_reuse(self):
        with tempfile.TemporaryDirectory() as root,patch('subtitle_identity.read',return_value=dict(d=[self.exact])) as fetch:
            for _ in range(2):self.assertEqual(resolve(self.film,root)['imdbId'],'tt1085492')
            self.assertEqual(fetch.call_count,1)
    def test_ambiguous_wrong_year_and_series_remain_unconfirmed(self):
        for rows in [[dict(self.exact,y=2015)],[dict(self.exact,qid='tvSeries')],[self.exact,dict(self.exact,id='tt1234567')]]:
            with tempfile.TemporaryDirectory() as root,patch('subtitle_identity.read',return_value=dict(d=rows)) as fetch:
                for _ in range(2):self.assertIsNone(resolve(self.film,root).get('imdbId'))
                self.assertEqual(fetch.call_count,1)
    def test_transient_error_backoff_and_official_identity_preserved(self):
        now=[1000]
        with tempfile.TemporaryDirectory() as root,patch('subtitle_identity.read',side_effect=OSError()) as fetch:
            for _ in range(2):resolve(self.film,root,clock=lambda:now[0])
            self.assertEqual(fetch.call_count,1);now[0]+=61;resolve(self.film,root,clock=lambda:now[0]);self.assertEqual(fetch.call_count,2)
            self.assertEqual(resolve(dict(self.film,imdbId='tt1085492'),root)['imdbId'],'tt1085492');self.assertEqual(fetch.call_count,2)
    def test_release_year_requires_exact_imdb_title_and_movie_type(self):
        film=dict(title='Nighthawks',year=2020,imdbId='tt6801218')
        exact=dict(id='tt6801218',l='Nighthawks',y=2019,qid='movie')
        for rows,expected in [([exact],2019),([dict(exact,id='tt0082817')],None),([dict(exact,l='Nighthawks II')],None),([dict(exact,qid='tvSeries')],None)]:
            with tempfile.TemporaryDirectory() as root,patch('subtitle_identity.read',return_value=dict(d=rows)) as fetch:
                for _ in range(2):self.assertEqual(release_year(film,root),expected)
                self.assertEqual(fetch.call_count,1)
                self.assertEqual(film['year'],2020)

if __name__=='__main__':unittest.main()
