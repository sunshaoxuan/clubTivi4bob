import tempfile
import unittest
from unittest.mock import patch
from subtitle_identity import resolve

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
if __name__=='__main__':unittest.main()
