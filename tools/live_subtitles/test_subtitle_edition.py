import unittest
from subtitle_edition import timing_evidence,chinese_script

class EditionTimingTests(unittest.TestCase):
    def fixtures(self):
        english=[dict(index=i+1,start=i*13.37+10,end=i*13.37+12.4,text='Dialogue') for i in range(100)]
        translated=[dict(c,text='訳文') for i,c in enumerate(english) if i%4!=0]
        facts=dict(provider='SubDL',imdbId='tt0387059',release='Bee.Season.2005.WEB-DL.DSNP')
        return english,translated,facts

    def test_different_segmentation_preserves_independent_cue_times(self):
        en,tr,facts=self.fixtures();q=timing_evidence(en,tr,facts,facts)
        self.assertEqual(q['method'],'same_imdb_release_distributed_interval_anchors')
        self.assertEqual(q['anchorCount'],75)
        self.assertNotEqual(len(en),len(tr))

    def test_remake_edition_identity_and_edited_timeline_fail_closed(self):
        en,tr,facts=self.fixtures()
        self.assertIsNone(timing_evidence(en,tr,facts,{**facts,'imdbId':'tt1234567'}))
        self.assertIsNone(timing_evidence(en,tr,facts,{**facts,'release':'Bee.Season.2005.DVD'}))
        shifted=[dict(c,start=c['start']+12,end=c['end']+12) for c in tr]
        self.assertIsNone(timing_evidence(en,shifted,facts,facts))
        cut=[dict(c,start=c['start']+(12 if i>20 else 0),end=c['end']+(12 if i>20 else 0)) for i,c in enumerate(tr)]
        self.assertIsNone(timing_evidence(en,cut,facts,facts))

    def test_short_or_early_only_coincidences_do_not_prove_whole_film(self):
        en,tr,facts=self.fixtures()
        self.assertIsNone(timing_evidence(en,tr[:20],facts,facts))
        wrong=[c if i<45 else dict(c,start=c['start']+3,end=c['end']+3) for i,c in enumerate(tr)]
        self.assertIsNone(timing_evidence(en,wrong,facts,facts))

    def test_provider_chinese_label_is_checked_against_actual_script(self):
        def cues(s):return [dict(text=s*4)]
        self.assertEqual(chinese_script(cues('這個問題讓我們學會認識國語和漢字'),'zh-CN'),'zh-TW')
        self.assertEqual(chinese_script(cues('这个问题让我们学会认识国语和汉字'),'zh-TW'),'zh-CN')
        self.assertIsNone(chinese_script(cues('共享文字天地人'),'zh'))


class EditionCacheTests(unittest.TestCase):
    def test_independent_language_cues_survive_cache_roundtrip_and_are_rechecked(self):
        from subtitle_cache import SubtitleCache
        import tempfile,json
        from pathlib import Path
        en,tr,facts=EditionTimingTests().fixtures()
        programme=dict(title='Bee Season',year=2005,imdbId='tt0387059')
        candidate=dict(page='https://dl.subdl.com/subtitle/1-2.zip',label='Bee.Season.2005.WEB-DL.DSNP',tracks={'en':en,'fr':tr},provenance={'en':facts,'fr':facts})
        with tempfile.TemporaryDirectory() as root:
            cache=SubtitleCache(Path(root)/'cache');folder=cache.root/cache.identity(programme);folder.mkdir();downloads=Path(root)/'downloads';downloads.mkdir()
            cache.store(folder,programme,[candidate],downloads)
            loaded,_=cache.load(folder)
            self.assertEqual([(round(c['start'],3),round(c['end'],3),c['text']) for c in loaded[0]['tracks']['fr']],
                             [(round(c['start'],3),round(c['end'],3),c['text']) for c in tr])
            p=folder/'index.json';m=json.loads(p.read_text());m['editions'][0]['tracks']['fr']['provenance']['release']='Another.Release';p.write_text(json.dumps(m))
            loaded,_=cache.load(folder);self.assertNotIn('fr',loaded[0]['tracks'])

if __name__=='__main__':unittest.main()
