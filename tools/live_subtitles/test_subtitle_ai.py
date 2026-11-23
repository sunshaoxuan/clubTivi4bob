import tempfile
import unittest
import json
from unittest.mock import patch

from subtitle_ai import SubtitleAI, TARGETS, transport_handlers, LocalTlsHandler
from subtitle_cache import SubtitleCache, verified_release_aliases
from subtitle_stremio import matches_bound_release
from client_clock import TextHub


class SubtitleAITest(unittest.TestCase):
    def test_local_gateway_requires_the_reviewed_tls_endpoint(self):
        with patch.dict('os.environ', {'BOBTV_SUBTITLE_AI_LOCAL_TLS':'1'}):
            handlers=transport_handlers('https://ccnode.briconbric.com:49531/v1')
            self.assertTrue(any(isinstance(handler,LocalTlsHandler) for handler in handlers))
            for base in ['https://other.example:49531/v1','http://ccnode.briconbric.com:49531/v1',
                         'https://ccnode.briconbric.com/v1']:
                with self.assertRaises(ValueError):transport_handlers(base)

    def english(self):
        return [dict(index=i,start=i*25,end=i*25+2,text='Test input') for i in range(105)]

    def test_rakuten_alias_applies_only_to_official_film(self):
        movie=dict(movieId='iron-fury-aka-t-34',imdbId='tt8820590',
                   identityEvidence='official_movie_record')
        alias,=verified_release_aliases(movie)
        self.assertTrue(matches_bound_release('T-34 2018 BluRay',alias,2018))
        self.assertFalse(matches_bound_release('T-34 2 2018 BluRay',alias,2018))
        self.assertEqual(verified_release_aliases(dict(movie,identityEvidence=None)),())

    def test_reviewed_localized_release_alias_requires_server_identity_evidence(self):
        movie=dict(imdbId='tt15341102',verifiedTitleAliases=['Mountain King','野王'],
            identityEvidence='reviewed_localized_title_pending_audio_verification')
        self.assertEqual(verified_release_aliases(movie),('Mountain King','野王'))
        self.assertEqual(verified_release_aliases(dict(movie,identityEvidence=None)),())
        self.assertEqual(verified_release_aliases(dict(movie,imdbId=None)),())

    def test_review_cannot_select_unoffered_records(self):
        with tempfile.TemporaryDirectory() as root:
            ai=SubtitleAI(root,lambda *_: {'indices':[1]})
            self.assertEqual(ai.review('Film',2018,'tt8820590',['One','Two']),{1})
            self.assertEqual(ai.review('Film',2018,'tt8820590',['One']),set())
            self.assertEqual(ai.review('Film',2018,None,['One','Two']),set())

    def test_full_track_reuses_times_and_cache(self):
        calls=[]
        def transport(_instruction, data):
            calls.append(data)
            return {'rows':[dict(id=c['id'],text='我们正在说话。') for c in data['cues']]}
        with tempfile.TemporaryDirectory() as root:
            ai=SubtitleAI(root,transport)
            english=self.english()
            result=ai.translate('Film',english)
            self.assertEqual(len(result),len(english))
            self.assertEqual([(c['start'],c['end']) for c in result],
                             [(c['start'],c['end']) for c in english])
            self.assertEqual(ai.translate('Film',english),result)
            self.assertEqual(len(calls),6)

    def test_partial_batch_does_not_publish_and_obeys_retry(self):
        calls=[]
        def transport(_instruction, data):
            calls.append(data)
            return {'rows':[dict(id=c['id'],text='我们正在说话。') for c in data['cues'][:-1]]}
        with tempfile.TemporaryDirectory() as root:
            ai=SubtitleAI(root,transport)
            self.assertIsNone(ai.translate('Film',self.english()))
            self.assertIsNone(ai.translate('Film',self.english()))
            self.assertEqual(len(calls),3)

    def test_generated_caption_is_labelled_and_human_chinese_replaces_it(self):
        english=self.english()
        ai=dict(page='a',tracks={'en':english,'zh-CN':english},
                provenance={'zh-CN':dict(generated=True)})
        human=dict(page='b',tracks={'en':english,'zh-CN':english})
        hub=TextHub.__new__(TextHub)
        hub.candidates=[ai]
        session=dict(reference=ai,language='zh-CN',audioLanguage='en',
                     windows=[dict(state='LOCKED',start=0,end=12,
                                   subtitleClock=dict(rate=1,intercept=0))])
        self.assertEqual(hub.caption_tracks(ai,0,12,1,0)[-1]['cues'][0]['text'],english[0]['text'])
        hub.candidates=[human]
        hub.refresh_reference_languages(session)
        self.assertIs(session['reference'],human)
        self.assertEqual(hub.preferred_track(human,'zh-CN'),'zh-CN')
        self.assertFalse(session['windows'][0]['tracks'][-1]['cues'][0]['text'].startswith('[AI] '))

    translations={'zh-CN':'我们正在说话。','zh-TW':'我們正在說話。',
                  'ja':'私たちは今話しています。','ko':'우리는 지금 이야기하고 있어요.',
                  'fr':'Nous sommes en train de parler.','es':'Estamos hablando ahora.'}

    def test_every_target_is_reviewed_cached_separately_and_preserves_cue_grid(self):
        calls=[]
        def transport(instruction,data):
            calls.append((data['targetLanguage'],'draft' in data))
            text=self.translations[data['targetLanguage']] if 'draft' in data else 'draft'
            return {'rows':[dict(id=c['id'],text=text) for c in data['cues']]}
        with tempfile.TemporaryDirectory() as root:
            ai=SubtitleAI(root,transport);english=self.english()[:45]
            for language in TARGETS:
                result=ai.translate('Film',english,language)
                self.assertIsNotNone(result,language)
                self.assertEqual([c['text'] for c in result],[self.translations[language]]*45)
                self.assertEqual([(c['index'],c['start'],c['end']) for c in result],
                                 [(c['index'],c['start'],c['end']) for c in english])
                count=len(calls);self.assertEqual(ai.translate('Film',english,language),result)
                self.assertEqual(len(calls),count)
            self.assertEqual(len(calls),24)
            self.assertEqual(sum(review for language,review in calls),12)

    def test_missing_exact_target_translates_even_if_other_chinese_or_provider_offline(self):
        calls=[];movie=dict(title='Film',year=2018,searchable=True,
            identityEvidence='official_movie_record',imdbId='tt8820590')
        english=self.english()[:5]
        reference=dict(page='a',tracks={'en':english,'zh-TW':english},
                       provenance={'en':dict(imdbId=movie['imdbId'])})
        with tempfile.TemporaryDirectory() as root:
            cache=SubtitleCache(root)
            def transport(instruction,data):
                calls.append(data)
                return {'rows':[dict(id=c['id'],text=self.translations[data['targetLanguage']]) for c in data['cues']]}
            cache.ai=SubtitleAI(cache.root/'.ai',transport)
            result=cache.with_ai_translation(movie,[reference],'zh-CN',reference_page='a')
            self.assertTrue(result[0]['provenance']['zh-CN']['generated'])
            self.assertEqual(len(calls),2)
            self.assertIs(cache.with_ai_translation(movie,result,'zh-CN'),result)
            self.assertIs(cache.with_ai_translation(dict(movie,identityEvidence=None),[reference],'ja')[0],reference)
            self.assertEqual(len(calls),2)
            self.assertIs(cache.with_ai_translation(movie,[reference],'ja',reference_page='other')[0],reference)

    def test_interrupted_later_batch_resumes_only_unfinished_review(self):
        calls=[];fail=True
        def transport(instruction,data):
            calls.append((data['cues'][0]['id'],'draft' in data))
            if fail and data['cues'][0]['id']==40 and 'draft' in data:
                raise OSError('transient')
            return {'rows':[dict(id=c['id'],text=self.translations['ja']) for c in data['cues']]}
        with tempfile.TemporaryDirectory() as root, patch('subtitle_ai.time.sleep'):
            ai=SubtitleAI(root,transport);english=self.english()[:45]
            self.assertIsNone(ai.translate('Film',english,'ja'))
            path=ai.root/(ai.translation_key(english,'ja')+'.json')
            data=json.loads(path.read_text());self.assertEqual(data['completedCues'],40)
            data['retryAfter']=0;path.write_text(json.dumps(data));fail=False;calls.clear()
            self.assertEqual(len(ai.translate('Film',english,'ja')),45)
            self.assertEqual(calls,[(40,True)])

    def test_exact_generated_script_precedes_other_script_and_native_exact_wins(self):
        english=self.english()
        row=dict(page='a',tracks={'en':english,'zh-CN':english,'zh-TW':english},
                 provenance={'zh-CN':dict(generated=True)})
        self.assertEqual(TextHub.preferred_track(row,'zh-CN'),'zh-CN')

    def test_default_provider_scope_is_enabled_without_secret_changes(self):
        with tempfile.TemporaryDirectory() as root, patch.dict('os.environ',{},clear=True):
            ai=SubtitleAI(root)
            self.assertTrue(ai.permits_translation({'provider':'Subtitle Cat'}))
            self.assertFalse(ai.permits_translation({'provider':'unverified'}))
            with patch.dict('os.environ',{'BOBTV_SUBTITLE_AI_TRANSLATION_ALLOWED_PROVIDERS':''}):
                self.assertFalse(ai.permits_translation({'provider':'Subtitle Cat'}))

    def test_current_playback_batch_first_and_only_reviewed_progress_is_published(self):
        calls=[];published=[]
        def transport(instruction,data):
            calls.append((data['cues'][0]['id'],'draft' in data))
            return {'rows':[dict(id=c['id'],text='私たちは今話しています。' if 'draft' in data else 'draft') for c in data['cues']]}
        with tempfile.TemporaryDirectory() as root:
            ai=SubtitleAI(root,transport);english=self.english()
            result=ai.translate('Film',english,'ja',priority_time=2100,on_progress=lambda rows:published.append(rows))
            self.assertEqual(calls[:2],[(80,False),(80,True)])
            self.assertEqual([row['index'] for row in published[0]],list(range(80,105)))
            self.assertTrue(all('draft' not in row['text'] for batch in published for row in batch))
            self.assertEqual([row['index'] for row in result],list(range(105)))
            self.assertEqual(published[-1],result)

    def test_partial_track_keeps_stable_choice_and_requires_entire_window_coverage(self):
        from subtitle_variants import SubtitleVariants
        from subtitle_edition import track_fingerprint
        english=self.english()[:45]
        def candidate(cues):
            return dict(page='a',tracks={'en':english,'ja':cues},provenance={'ja':dict(
                generated=True,partial=len(cues)!=len(english),pipeline=3,referenceFingerprint=track_fingerprint(english))})
        partial=candidate(english[40:]);full=candidate(english)
        catalogue=SubtitleVariants([full]);choice=catalogue.track(full,'ja')['id']
        self.assertEqual(catalogue.track(partial,'ja')['id'],choice)
        self.assertTrue(catalogue.supports(partial,choice))
        hub=TextHub.__new__(TextHub);hub.candidates=[partial]
        self.assertEqual({t['language'] for t in hub.caption_tracks(partial,975,1001,1,0)},{'en'})
        self.assertEqual({t['language'] for t in hub.caption_tracks(partial,1000,1001,1,0)},{'en','ja'})

    def test_equivalent_english_alias_reuses_ready_cache_and_its_own_times(self):
        from subtitle_edition import translation_fingerprint
        calls=[]
        def transport(_instruction,data):
            calls.append(data)
            return {'rows':[dict(id=c['id'],text='私たちは牧場に向かっています。') for c in data['cues']]}
        english=[{**c,'text':f'We work at M & H ranch. Line {i}.'} for i,c in enumerate(self.english()[:45])]
        alternate=[{**c,'text':c['text'].replace(' & ',' and '),'start':c['start']+20,'end':c['end']+20} for c in english]
        self.assertEqual(translation_fingerprint(english),translation_fingerprint(alternate))
        movie=dict(title='Film',year=2018,searchable=True,imdbId='tt8820590',identityEvidence='official_movie_record')
        first=dict(page='a',tracks={'en':english},provenance={'en':dict(imdbId=movie['imdbId'],provider='SubDL')})
        second=dict(page='b',tracks={'en':alternate},provenance=first['provenance'])
        with tempfile.TemporaryDirectory() as root:
            cache=SubtitleCache(root);cache.ai=SubtitleAI(cache.root/'.ai',transport)
            result=cache.with_ai_translation(movie,[first,second],'ja',reference_page='a')
            self.assertEqual(len(calls),4)
            # Restart the cache object and choose the other provider/clock.
            cache=SubtitleCache(root);cache.ai=SubtitleAI(cache.root/'.ai',transport)
            result=cache.with_ai_translation(movie,[first,second],'ja',reference_page='b')
            self.assertEqual(len(calls),4)
            self.assertEqual([(c['start'],c['end']) for c in result[1]['tracks']['ja']],
                             [(c['start'],c['end']) for c in alternate])
            changed=[{**c,'text':c['text'].replace('work','do not work')} for c in alternate]
            self.assertNotEqual(translation_fingerprint(english),translation_fingerprint(changed))

    def test_old_partial_caches_merge_without_retranslating_reviewed_batches(self):
        from subtitle_ai import PIPELINE
        calls=[]
        def transport(_instruction,data):
            calls.append(data['cues'][0]['id'])
            return {'rows':[dict(id=c['id'],text='新しく翻訳しました。') for c in data['cues']]}
        english=[{**c,'text':'We work at M & H ranch.'} for c in self.english()]
        other=[{**c,'text':'We work at M and H ranch.','start':c['start']+20,'end':c['end']+20} for c in english]
        with tempfile.TemporaryDirectory() as root:
            ai=SubtitleAI(root,transport)
            for cues,start in [(english,0),(other,40)]:
                rows=[dict(id=i,text='以前に校正しました。') for i in range(start,start+40)]
                ai.save(ai.root/(ai.translation_key(cues,'ja')+'.json'),dict(pipeline=PIPELINE,
                    language='ja',phase='waiting',totalCues=105,completedCues=40,
                    batches={str(start):dict(reviewed=rows)}))
            result=ai.translate('Film',english,'ja',equivalent_english=[english,other])
            self.assertEqual(len(result),105)
            self.assertEqual(calls,[80,80])
            self.assertEqual([c['text'] for c in result[:80]],['以前に校正しました。']*80)
            self.assertEqual(ai.translate('Film',english,'ja'),result)
            self.assertEqual(calls,[80,80])

    def test_inflight_cache_exposes_only_reviewed_progress_without_another_call(self):
        import fcntl
        from subtitle_ai import PIPELINE
        english=self.english()[:45]
        with tempfile.TemporaryDirectory() as root:
            ai=SubtitleAI(root,lambda *_:self.fail('duplicate AI request'))
            key=ai.translation_key(english,'ja')
            ai.save(ai.root/(key+'.json'),dict(pipeline=PIPELINE,language='ja',phase='proofreading',
                batches={'0':dict(reviewed=[dict(id=i,text='校正済みです。') for i in range(40)]),
                         '40':dict(draft=[dict(id=i,text='draft') for i in range(40,45)])}))
            with (ai.root/(key+'.lock')).open('a') as lock:
                fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
                result=ai.translate('Film',english,'ja')
            self.assertEqual(len(result),40)
            self.assertTrue(all(c['text']=='校正済みです。' for c in result))

    def test_cue_boundaries_and_real_word_changes_keep_separate_translation_sources(self):
        from subtitle_edition import translation_fingerprint
        a=[dict(index=1,start=0,end=2,text='Do not go.'),dict(index=2,start=2,end=4,text='Wait here.')]
        b=[dict(index=1,start=0,end=4,text='Do not go. Wait here.')]
        self.assertNotEqual(translation_fingerprint(a),translation_fingerprint(b))
        self.assertNotEqual(translation_fingerprint(a),translation_fingerprint([{**a[0],'text':'Do go.'},a[1]]))
