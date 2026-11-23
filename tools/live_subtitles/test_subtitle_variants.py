import tempfile
import unittest
from unittest.mock import patch

import test_client_clock
from subtitle_variants import SubtitleVariants


class SubtitleVariantsTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.helper = test_client_clock.ClientClockTests()
        self.hub = self.helper.hub(temp.name)
        self.token = self.hub.create(self.hub.source, None, 'zh-CN', ['clientClockV1'])
        self.original = self.hub.candidates[0]
        self.state = self.hub.sessions[self.token]

    def translation(self, suffix, *, page=None, offset=0, provider='SubDL'):
        reference = [{**cue, 'start': cue['start']+offset, 'end': cue['end']+offset}
                     for cue in self.original['tracks']['en']]
        local = [{**cue, 'start': cue['start']+.15, 'text': f'译本 {suffix} {index}'}
                 for index, cue in enumerate(reference)]
        return dict(page=page or self.original['page'], label=suffix,
                    provenance={'zh-CN': dict(provider=provider)}, tracks={'en': reference, 'zh-CN': local})

    def prepare(self, *variants):
        self.hub.candidates = list(variants)
        self.state.update(reference=variants[0], lastMatchedReference=variants[0],
                          rate=1., intercept=100., asset='movie-asset', rateVerified=True)
        self.hub.clock_window(self.state, variants[0], 0, 40, 1., 100.)

    def choose(self, candidate, language='zh-CN'):
        return self.hub.variant_catalog().track(candidate, language)['id']

    def test_choices_cap_per_language_and_mirror_duplicates(self):
        variants = [self.translation(str(index), provider='source' + str(index % 2)) for index in range(5)]
        mirror = self.translation('0', page='mirror', offset=2, provider='mirror')
        catalogue = SubtitleVariants([variants[0], mirror, *variants[1:]])
        self.assertEqual(catalogue.track(variants[0], 'zh-CN')['id'], catalogue.track(mirror, 'zh-CN')['id'])
        options = [choice for choice in catalogue.choices(variants[0]) if choice['language'] == 'zh-CN']
        self.assertEqual(len(options), 3)
        self.assertEqual(len({item['id'] for item in options}), 3)
        self.assertEqual(options[0], catalogue.track(variants[0], 'zh-CN'))

    def test_instant_replacement_preserves_translated_cue_timings(self):
        first, second = self.translation('first'), self.translation('second')
        self.prepare(first, second)
        choice = self.choose(second)
        self.hub.set_language(self.token, 'zh-CN', variant=choice)
        result = self.hub.response(self.token)
        self.assertEqual(result['subtitleStatus']['activeVariantId'], choice)
        self.assertEqual(result['subtitleStatus']['selectedVariantId'], choice)
        chosen = next(track for track in result['windows'][0]['tracks'] if track['variantId'] == choice)
        self.assertAlmostEqual(chosen['cues'][0]['start'], 3.15)
        self.assertIn('second', chosen['cues'][0]['text'])
        self.assertIs(self.state['reference'], second)
        # A concurrent speech observation using the old language cannot clear the pin.
        self.hub.set_language(self.token, 'ja')
        self.assertEqual(self.state['language'], 'zh-CN')
        self.assertEqual(self.state['variantId'], choice)

    def test_shifted_cut_waits_for_fresh_voice_and_ignores_outside_programme_id(self):
        first, shifted = self.translation('first'), self.translation('shifted', page='other-cut', offset=8)
        self.prepare(first, shifted)
        choice = self.choose(shifted)
        self.hub.set_language(self.token, 'zh-CN', variant=choice)
        before = self.hub.response(self.token)
        self.assertEqual(before['subtitleStatus']['selectedVariantId'], choice)
        self.assertIsNone(before['subtitleStatus']['activeVariantId'])
        self.assertEqual(before['windows'], [])
        self.assertEqual(before['subtitleStatus']['phase'], 'synchronizing')
        observed = self.helper.observation(self.hub, words=[dict(word='spoken', start=0, end=1, probability=1.)])
        anchors = [dict(anchor, subtitleStart=anchor['subtitleStart']+8, offset=108.)
                   for anchor in self.helper.anchors()]
        with patch('client_clock.align', return_value=(108., anchors)) as align:
            self.hub.ingest(self.token, observed)
        self.assertIs(self.state['reference'], shifted)
        self.assertIs(align.call_args.args[1], shifted['tracks']['en'])
        self.assertEqual(self.hub.response(self.token)['subtitleStatus']['activeVariantId'], choice)
        self.hub.set_language(self.token, 'zh-CN', variant='f'*64)
        self.assertIsNone(self.hub.response(self.token)['subtitleStatus']['selectedVariantId'])

    def test_variant_change_on_ad_never_displays_old_film_and_resets_on_new_programme(self):
        first, second = self.translation('first'), self.translation('second')
        self.prepare(first, second)
        ad = self.helper.observation(self.hub, epoch=2, asset='advert', ad=True, start=40, end=50)
        self.hub.ingest(self.token, ad)
        choice = self.choose(second)
        self.hub.set_language(self.token, 'zh-CN', variant=choice)
        result = self.hub.response(self.token)
        self.assertIsNone(result['subtitleStatus']['activeVariantId'])
        self.assertEqual([w['state'] for w in result['windows']], ['SUSPENDED'])
        self.hub.programme['key'] = 'next'
        result = self.hub.response(self.token)
        self.assertIsNone(result['subtitleStatus']['selectedVariantId'])
        self.assertEqual(result['windows'], [])


    def test_only_one_ai_choice_per_language_preserves_active_and_pinned_ids(self):
        a=self.translation('AI first');b=self.translation('AI second',page='b',offset=20)
        human=self.translation('native',page='human',provider='native')
        for row in [a,b]:
            row['provenance']['zh-CN'].update(generated=True,referenceFingerprint=row['page'],pipeline=3)
        catalog=SubtitleVariants([a,b,human]);first=catalog.track(a,'zh-CN')['id'];second=catalog.track(b,'zh-CN')['id']
        choices=[c for c in catalog.choices(a) if c['language']=='zh-CN']
        self.assertEqual([c['id'] for c in choices if c['generated']],[first])
        choices=[c for c in catalog.choices(a,second) if c['language']=='zh-CN']
        self.assertEqual([c['id'] for c in choices if c['generated']],[second])
        self.assertTrue(any(not c['generated'] for c in choices))
        self.assertTrue(catalog.supports(a,first));self.assertTrue(catalog.supports(b,second))


if __name__ == '__main__':
    unittest.main()
