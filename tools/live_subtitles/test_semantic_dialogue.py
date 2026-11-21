import copy
import json
import threading
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from semantic_dialogue import SemanticDialogue, prepare, validate, confirm

PHRASES=['请把窗户轻轻打开然后看看外面的天气怎么样',
         '今天晚上大家一起去餐厅吃一顿热乎乎的晚饭',
         '明天早上记得给妈妈打个电话告诉她我们很平安',
         '把那扇蓝色的大门关好之后再回来坐下来休息',
         '他们已经在火车站旁边等了我们很长很长时间',
         '现在我们应该开始认真准备明天的工作安排了',
         '你最好现在就把昨天发生的事情全部告诉我',
         '我们明天下午会在学校门口等你一起回家',
         '医生说她只要好好休息几天就能够恢复健康',
         '如果天气一直这么冷大家出门都应该穿厚衣服']


def fixture(count=6, origin=0, cue_origin=10, intercept=100, rate=25/24, phrase_offset=0):
    words=[];cues=[];pairs=[]
    for i in range(count):
        first=len(words);at=origin+i*10
        for n,ch in enumerate(PHRASES[(i+phrase_offset)%len(PHRASES)]):
            words.append(dict(word=ch,start=at+n*.12,end=at+n*.12+.1,
                              onset=at+n*.12,probability=.98))
        cue=cue_origin+i
        cues.append(dict(index=cue,start=rate*at+intercept,end=rate*at+intercept+4,text=PHRASES[(i+phrase_offset)%len(PHRASES)]))
        pairs.append(dict(first=first,last=len(words)-1,cue=cue))
    return words,cues,dict(pairs=pairs),dict(subtitleCues=[[c['index'],c['text']] for c in cues])


class SemanticDialogueTests(unittest.TestCase):
    def test_failed_acquisition_backs_off_and_reserves_independent_holdout_calls(self):
        words,cues,answer,request=fixture()
        candidate=dict(page='verified',tracks={'zh-CN':cues,'en':cues},
            provenance={tag:dict(imdbId='tt0421729') for tag in ['zh-CN','en']})
        session=dict(programmeKey='programme',epoch=1,asset='movie',variantId=None,ad=False)
        calls=[];lock=threading.RLock()
        def call(*args,**kwargs):calls.append(1);return answer
        matcher=SemanticDialogue(SimpleNamespace(enabled=True,call=call),lock,
            lambda:{'token':session},lambda:[candidate],lambda *a,**k:None)
        def feed(end):
            with lock:matcher.offer('token',session,dict(title='Film',imdbId='tt0421729'),
                                    candidate,'zh-CN',words,end-60,end)
            deadline=time.monotonic()+2
            while matcher.busy and time.monotonic()<deadline:time.sleep(.01)
            self.assertFalse(matcher.busy)
        proof=validate(answer,request,words,cues)
        with patch.dict('os.environ',{'BOBTV_SUBTITLE_SEMANTIC_CLOCK':'1'}), \
                patch('semantic_dialogue.prepare',return_value=(request,words)), \
                patch('semantic_dialogue.validate',side_effect=[None,None,None,proof,None,None]):
            feed(60);feed(90);self.assertEqual(len(calls),1)
            feed(120);feed(180);self.assertEqual(len(calls),2)
            feed(240);feed(360);self.assertEqual(len(calls),3)
            feed(480);self.assertEqual(len(calls),4)
            self.assertIn('hypothesis',session['semanticState'])
            feed(510);feed(540);self.assertEqual(len(calls),6)
            feed(600);self.assertEqual(len(calls),6)

    def test_independent_unseen_utterances_confirm_the_same_fps_clock(self):
        words,cues,answer,request=fixture()
        first=validate(answer,request,words,cues)
        self.assertIsNotNone(first)
        words,cues,answer,request=fixture(4,80,30)
        second=validate(answer,request,words,cues,confirmation=True)
        result=confirm(first,second)
        self.assertIsNotNone(result)
        self.assertEqual(len(result['anchors']),10)
        self.assertAlmostEqual(result['rate'],25/24)
        self.assertLess(result['error'],1e-8)

    def test_close_frame_rate_hypotheses_bound_future_projection(self):
        words,cues,answer,request=fixture()
        model=validate(answer,request,words,cues)
        self.assertIsNotNone(model)
        self.assertGreaterEqual(model['projectionLimit'],30)
        self.assertLess(model['projectionLimit'],1800)

    def test_model_cannot_supply_clock_values_or_unoffered_indices(self):
        words,cues,answer,request=fixture()
        for altered in [dict(answer,intercept=123),dict(pairs=[dict(answer['pairs'][0],asrStart=1)]),
                        dict(pairs=[dict(answer['pairs'][0],cue=999)]),
                        dict(pairs=[dict(answer['pairs'][0],first=True)]),
                        dict(pairs=[dict(answer['pairs'][0],last=len(words))])]:
            self.assertIsNone(validate(altered,request,words,cues))

    def test_duplicate_overlapping_and_unordered_dialogue_is_rejected(self):
        words,cues,answer,request=fixture()
        repeated=copy.deepcopy(answer);repeated['pairs'][1]=dict(repeated['pairs'][0])
        self.assertIsNone(validate(repeated,request,words,cues))
        overlap=copy.deepcopy(answer);overlap['pairs'][1]['first']=0
        self.assertIsNone(validate(overlap,request,words,cues))
        self.assertIsNone(validate(dict(pairs=answer['pairs'][::-1]),request,words,cues))

    def test_weak_onsets_and_low_confidence_speech_never_prove_a_clock(self):
        words,cues,answer,request=fixture()
        for pair in answer['pairs']:words[pair['first']]['probability']=.39
        self.assertIsNone(validate(answer,request,words,cues))
        for word in words:word['probability']=.7
        self.assertIsNone(validate(answer,request,words,cues))

    def test_long_confident_utterance_keeps_the_existing_point_four_onset_floor(self):
        words,cues,answer,request=fixture()
        for pair in answer['pairs']:words[pair['first']]['probability']=.45
        self.assertIsNotNone(validate(answer,request,words,cues))

    def test_wrong_holdout_offset_and_reused_speech_are_rejected(self):
        words,cues,answer,request=fixture();first=validate(answer,request,words,cues)
        self.assertIsNone(confirm(first,first))
        words,cues,answer,request=fixture(4,80,30,intercept=102)
        second=validate(answer,request,words,cues,confirmation=True)
        self.assertIsNone(confirm(first,second))

    def test_fewer_than_five_initial_dialogues_never_synchronize(self):
        words,cues,answer,request=fixture(4)
        self.assertIsNone(validate(answer,request,words,cues))

    def test_request_is_time_blind_and_preserves_equal_onsets_in_one_window(self):
        words,cues,_,_=fixture()
        words[1]['start']=words[0]['start'];words[1]['onset']=words[0]['onset']
        result=prepare(cues,[dict(start=0,end=60,words=words)],dict(title='Film',imdbId='tt0421729'))
        self.assertIsNotNone(result);request,observed=result
        self.assertEqual(len(observed),len(words))
        def keys(value):
            if isinstance(value,dict):
                for key,item in value.items():yield key;yield from keys(item)
            elif isinstance(value,list):
                for item in value:yield from keys(item)
        self.assertFalse({'start','end','onset','rate','intercept'} & set(keys(request)))
        self.assertLess(len(json.dumps(request,ensure_ascii=False).encode()),19001)

    def test_callback_from_an_old_epoch_or_changed_resource_cannot_be_promoted(self):
        for mutation in ['epoch','resource']:
            words,cues,answer,_=fixture();entered=threading.Event();release=threading.Event()
            def call(*args,**kwargs):entered.set();release.wait(2);return answer
            ai=SimpleNamespace(enabled=True,call=call);lock=threading.RLock()
            candidate=dict(page='verified',tracks={'zh-CN':cues,'en':cues},
                           provenance={language:dict(imdbId='tt0421729') for language in ['zh-CN','en']})
            candidates=[candidate];session=dict(programmeKey='programme',epoch=1,asset='movie',variantId=None,ad=False)
            sessions={'token':session};events=[]
            matcher=SemanticDialogue(ai,lock,lambda:sessions,lambda:candidates,lambda kind,**facts:events.append(kind))
            with patch.dict('os.environ',{'BOBTV_SUBTITLE_SEMANTIC_CLOCK':'1'}):
                with lock:
                    matcher.offer('token',session,dict(title='Film',imdbId='tt0421729'),candidate,'zh-CN',words,0,60)
                self.assertTrue(entered.wait(1))
                with lock:
                    if mutation=='epoch':session['epoch']=2;session.pop('semanticState')
                    else:candidates[:]=[dict(candidate,tracks={'zh-CN':[dict(cues[0],start=999)],'en':cues})]
                release.set();deadline=time.monotonic()+2
                while matcher.busy and time.monotonic()<deadline:time.sleep(.01)
                self.assertFalse(matcher.busy)
            self.assertNotIn('semantic_dialogue_pending',events)
            self.assertNotIn('semantic_dialogue_verified',events)

    def test_async_two_stage_flow_produces_a_scoped_ready_model(self):
        words,cues,_,_=fixture()
        newer,new_cues,_,_=fixture(4,80,30,phrase_offset=6)
        all_cues=cues+new_cues;calls=[]
        def call(instruction,data,**kwargs):
            calls.append(data);observed=[p[1] for p in data['observedWords']];pairs=[]
            for cue,text in data['subtitleCues']:
                needle=list(text)
                places=[i for i in range(len(observed)-len(needle)+1) if observed[i:i+len(needle)]==needle]
                if len(places)==1:pairs.append(dict(first=places[0],last=places[0]+len(needle)-1,cue=cue))
            return dict(pairs=sorted(pairs,key=lambda p:p['first'])[:8])
        candidate=dict(page='verified',tracks={'zh-CN':all_cues,'en':all_cues},
            provenance={tag:dict(imdbId='tt0421729') for tag in ['zh-CN','en']})
        session=dict(programmeKey='programme',epoch=1,asset='movie',variantId=None,ad=False)
        lock=threading.RLock();matcher=SemanticDialogue(SimpleNamespace(enabled=True,call=call),lock,
            lambda:{'token':session},lambda:[candidate],lambda *a,**k:None)
        identity=dict(title='Film',imdbId='tt0421729')
        def feed(source,start,end):
            observed=[dict(w,start=w['start']-start,end=w['end']-start) for w in source if start<=w['start']<end]
            with lock:matcher.offer('token',session,identity,candidate,'zh-CN',observed,start,end)
            deadline=time.monotonic()+2
            while matcher.busy and time.monotonic()<deadline:time.sleep(.01)
            self.assertFalse(matcher.busy)
        with patch.dict('os.environ',{'BOBTV_SUBTITLE_SEMANTIC_CLOCK':'1'}):
            feed(words,0,40);feed(words,30,70)
            self.assertTrue('hypothesis' in session['semanticState'],'first independent dialogue proof was not retained')
            self.assertNotIn('ready',session['semanticState'])
            feed(newer,80,120)
            self.assertTrue('ready' in session['semanticState'],'independent holdout was not promoted')
            selected=matcher.take(session,[candidate],125,'zh-CN')
        self.assertIs(selected[0],candidate)
        self.assertEqual(len(selected[1]),10)
        self.assertAlmostEqual(selected[2],25/24)
        self.assertEqual(len(calls),2)

    def test_qa_gate_allows_only_the_reviewed_diagnostic_session(self):
        ai=SimpleNamespace(enabled=True)
        matcher=SemanticDialogue(ai,threading.RLock(),lambda:{},lambda:[],lambda *a,**k:None)
        path=SimpleNamespace(is_symlink=lambda:False,stat=lambda:SimpleNamespace(st_uid=0,st_size=40),
                             read_text=lambda:json.dumps(['a'*32]))
        with patch.dict('os.environ',{'BOBTV_SUBTITLE_SEMANTIC_CLOCK':'1','BOBTV_SUBTITLE_SEMANTIC_QA_ONLY':'1'}), patch('semantic_dialogue.Path',return_value=path):
            self.assertTrue(matcher.allowed('a'*32))
            self.assertFalse(matcher.allowed('b'*32))
            self.assertFalse(matcher.allowed(None))
            path.is_symlink=lambda:True
            self.assertFalse(matcher.allowed('a'*32))

    def test_unverified_identity_and_generated_tracks_do_not_trigger_ai(self):
        calls=[];matcher=SemanticDialogue(SimpleNamespace(enabled=True,call=lambda *a,**k:calls.append(a)),
            threading.RLock(),lambda:{},lambda:[],lambda *a,**k:None)
        words,cues,_,_=fixture()
        candidate=dict(page='wrong-film',tracks={'zh-CN':cues,'en':cues},
            provenance={'zh-CN':dict(imdbId='tt0000001'),'en':dict(imdbId='tt0000001')})
        with patch.dict('os.environ',{'BOBTV_SUBTITLE_SEMANTIC_CLOCK':'1'}):
            self.assertFalse(matcher.offer('x',{},dict(title='Film',imdbId='tt0421729'),candidate,'zh-CN',words,0,60))
        self.assertEqual(calls,[])


if __name__=='__main__':unittest.main()
