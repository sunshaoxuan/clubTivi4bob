import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import subtitle_subdl as adapter

SRT=b'1\n00:00:01,000 --> 00:00:02,000\nOne\n\n2\n00:00:03,000 --> 00:00:04,000\nTwo\n\n3\n00:00:05,000 --> 00:00:06,000\nThree\n'
def archive(raw=SRT):
    out=io.BytesIO()
    with zipfile.ZipFile(out,'w') as z:z.writestr('film.srt',raw)
    return out.getvalue()

def page(language='english',label='The.Prince.2014.BluRay',number='1-2'):
    return f'<div data-language="{language}" data-language-name="lang"><a data-subtitle-title href="/s/info/x"><h4>{label}</h4></a><a data-subtitle-download href="https://dl.subdl.com/subtitle/{number}.zip">Quick Download</a></div>'

class SubdlTests(unittest.TestCase):
    movie=dict(type='movie',name='The Prince',original_name='The Prince',year=2014,link='/subtitle/sd10016/the-prince')
    def test_imdb_lookup_downloads_existing_files_and_never_requests_translation(self):
        urls=[]
        def read(url):
            urls.append(url)
            if '/auto?' in url:return json.dumps(dict(results=[self.movie])).encode()
            if url.startswith('https://subdl.com/'):
                return (page()+page('french',number='3-4')+page('big_5_code',number='5-6')).encode()
            return archive()
        with tempfile.TemporaryDirectory() as root,patch.object(adapter,'read',read):
            rows=adapter.discover('The Prince',2014,root,imdb_id='tt1085492')
            self.assertEqual(len(rows),1);self.assertEqual(set(rows[0]['tracks']),{'en','fr','zh-TW'})
            self.assertTrue(any('query=tt1085492' in u for u in urls))
            self.assertFalse(any('translate' in u for u in urls))
            self.assertEqual(rows[0]['provenance']['en']['imdbId'],'tt1085492')
            self.assertTrue(list(Path(root).glob('*.srt')))
    def test_ambiguous_lookup_and_wrong_year_are_not_admitted(self):
        for movies in [[self.movie,self.movie],[{**self.movie,'year':2019}],[{**self.movie,'original_name':'The Prince and the 108 Demons'}]]:
            with tempfile.TemporaryDirectory() as root,patch.object(adapter,'read',return_value=json.dumps(dict(results=movies)).encode()):
                self.assertEqual(adapter.discover('The Prince',2014,root,imdb_id='tt1085492'),[])
    def test_prefix_collision_in_release_is_rejected_even_on_right_page(self):
        def read(url):
            return json.dumps(dict(results=[self.movie])).encode() if '/auto?' in url else page(label='The.Prince.and.the.108.Demons.2014').encode()
        with tempfile.TemporaryDirectory() as root,patch.object(adapter,'read',read):
            self.assertEqual(adapter.discover('The Prince',2014,root,imdb_id='tt1085492'),[])
    def test_parser_maps_all_seven_languages_and_rejects_foreign_download_hosts(self):
        p=adapter.Releases();p.feed(''.join(page(code,number=f'{i+1}-2') for i,code in enumerate(adapter.LANGUAGE_CODES)))
        self.assertEqual({r['language'] for r in p.rows},set(adapter.LANGUAGES))
        p=adapter.Releases();p.feed(page().replace('dl.subdl.com','unreviewed.example'));self.assertEqual(p.rows,[])
    def test_archive_utf16_and_expansion_limits(self):
        data,cues=adapter.unpack(archive(SRT.decode().encode('utf-16')));self.assertEqual(len(cues),3)
        with self.assertRaises(zipfile.BadZipFile):adapter.unpack(b'not a zip')
        out=io.BytesIO()
        with zipfile.ZipFile(out,'w') as z:
            for i in range(17):z.writestr(str(i)+'.srt',SRT)
        with self.assertRaisesRegex(ValueError,'archive_limit'):adapter.unpack(out.getvalue())
    def test_nonmatching_translation_grid_is_not_assumed_to_share_english_clock(self):
        def read(url):
            if '/auto?' in url:return json.dumps(dict(results=[self.movie])).encode()
            if url.startswith('https://subdl.com/'):return (page()+page('french',number='3-4')).encode()
            return archive(SRT.replace(b'00:00:01,000',b'00:00:01,500')) if '3-4' in url else archive()
        with tempfile.TemporaryDirectory() as root,patch.object(adapter,'read',read):
            rows=adapter.discover('The Prince',2014,root,imdb_id='tt1085492');self.assertEqual(set(rows[0]['tracks']),{'en'})
    def test_primary_provider_failure_still_tries_imdb_fallback(self):
        import subtitle_catalog
        row=dict(page='existing',label='The.Prince.2014.BluRay',tracks={'en':[]})
        with tempfile.TemporaryDirectory() as root,patch.object(subtitle_catalog,'_discover_subtitlecat',side_effect=OSError('first provider unavailable')),patch.object(adapter,'discover',return_value=[row]) as fallback:
            rows=subtitle_catalog.discover('The Prince',2014,root,imdb_id='tt1085492')
            self.assertEqual(rows,[row]);self.assertEqual(fallback.call_args.kwargs['imdb_id'],'tt1085492')

    def test_resource_scope_blocks_arbitrary_hosts_and_ports_before_network(self):
        for url in ['https://unreviewed.example/subtitle/1-2.zip','https://dl.subdl.com:444/subtitle/1-2.zip','https://subdl.com/unreviewed','http://dl.subdl.com/subtitle/1-2.zip']:
            with self.assertRaises(ValueError):adapter.read(url)

if __name__=='__main__':unittest.main()
