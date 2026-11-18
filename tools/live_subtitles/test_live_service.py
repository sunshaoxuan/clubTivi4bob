import json
from pathlib import Path
import tempfile
import time
import threading
import unittest
from unittest.mock import patch

from live_media import parse_media, playlist, continuous_counters, MediaPublisher
from live_engine import Engine, align, fit_clock_rate, mapped_cues, clock_rate_confident
from service import Hub, CHANNEL, pilot_channel, media_route, official_imdb_id
from subtitle_catalog import discover, parse_srt, title_norm, matches_movie_title


class LiveServiceTests(unittest.TestCase):
    def test_unchanged_verified_snapshot_is_not_downloaded_again(self):
        import gzip,hashlib,service
        raw=gzip.compress(json.dumps(dict(channels=[])).encode());digest=hashlib.sha256(raw).hexdigest()
        manifest=json.dumps(dict(snapshotUrl='/api/v1/channel-catalog/snapshots/'+digest+'.json.gz',sha256=digest)).encode()
        with patch.dict(service._SNAPSHOT_CACHE,{},clear=True),patch('service.public_read',side_effect=[manifest,raw,manifest]) as read:
            self.assertEqual(service.snapshot('channel-catalog'),dict(channels=[]))
            self.assertEqual(service.snapshot('channel-catalog'),dict(channels=[]))
            self.assertEqual(read.call_count,3)

    def test_prewarm_starts_without_a_client_and_survives_last_viewer_expiry(self):
        from unittest.mock import Mock
        from types import SimpleNamespace
        hub=Hub.__new__(Hub);hub.lock=threading.RLock();hub.sessions={};hub.prewarm=True
        hub.next_bootstrap=0;hub.engine=None;hub.source='reviewed'
        hub.valid_context=lambda *a:True;hub.ensure_engine=Mock()
        hub.expire_and_prewarm();hub.ensure_engine.assert_called_once_with()
        stop=threading.Event();control=threading.Event()
        hub.engine=SimpleNamespace(collector=SimpleNamespace(stop=stop),controller_stop=control)
        hub.sessions={'expired':dict(lastAccess=time.time()-181)}
        hub.expire_and_prewarm()
        self.assertEqual(hub.sessions,{})
        self.assertFalse(stop.is_set());self.assertFalse(control.is_set())

    def test_idle_prewarm_recovers_expired_provider_media_session(self):
        from types import SimpleNamespace
        from unittest.mock import Mock
        stop=threading.Event();control=threading.Event()
        hub=Hub.__new__(Hub);hub.lock=threading.RLock();hub.sessions={};hub.prewarm=True;hub.next_bootstrap=0
        hub.engine=SimpleNamespace(collector=SimpleNamespace(stop=stop,snapshot=lambda:[dict(downloadedWall=time.time()-46)]),controller_stop=control)
        hub.publisher=object();hub.source='reviewed';hub.valid_context=lambda *a:True;hub.ensure_engine=Mock()
        hub.expire_and_prewarm();self.assertTrue(stop.is_set());self.assertTrue(control.is_set())
        hub.ensure_engine.assert_called_once_with()

    def test_on_demand_mode_keeps_existing_idle_shutdown(self):
        from types import SimpleNamespace
        hub=Hub.__new__(Hub);hub.lock=threading.RLock();hub.sessions={};hub.prewarm=False
        stop=threading.Event();control=threading.Event()
        hub.engine=SimpleNamespace(collector=SimpleNamespace(stop=stop),controller_stop=control)
        hub.publisher=object();hub.expire_and_prewarm()
        self.assertTrue(stop.is_set());self.assertTrue(control.is_set())
        self.assertIsNone(hub.engine);self.assertIsNone(hub.publisher)

    def test_programme_handover_without_viewers_keeps_collector_and_sibling_paths(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as root:
            collector=SimpleNamespace(source='reviewed',root=Path(root)/'media',snapshot=lambda:[dict(sequence=123)])
            old=SimpleNamespace(root=collector.root/'programmes'/'old',collector=collector,controller_stop=threading.Event())
            hub=Hub.__new__(Hub);hub.engine=old;hub.sessions={};hub.model=None;hub.ffmpeg='ffmpeg';hub.subtitle_cache=None
            with patch('service.Engine') as make:
                hub.handover(dict(movieId='next'))
                self.assertEqual(make.call_args.args[2].parent,collector.root/'programmes')
                self.assertEqual(make.call_args.kwargs['preferred_language'],'en')
                self.assertIs(hub.engine.collector,collector)
                self.assertEqual(hub.engine.last_sequence,123)
                hub.engine.start.assert_called_once_with(collect=False)
            self.assertTrue(old.controller_stop.is_set())

    def test_hardened_service_allows_only_its_media_and_cache_writes(self):
        import shlex
        unit=(Path(__file__).parent/'bobtv-live-subtitles.service').read_text()
        settings=dict(line.split('=',1) for line in unit.splitlines() if '=' in line)
        arguments=shlex.split(settings['ExecStart']);writable=settings['ReadWritePaths'].split()
        for option in ['--root','--subtitle-cache-root']:
            self.assertIn(arguments[arguments.index(option)+1],writable)
        self.assertEqual(settings['ProtectSystem'],'strict')
        self.assertEqual(settings['ProtectHome'],'true')
        self.assertNotIn('/var/lib/bobtv',writable)

    def test_only_unambiguous_official_imdb_identifiers_are_admitted(self):
        self.assertEqual(official_imdb_id({'imdb_id':'tt1234567'}),'tt1234567')
        self.assertEqual(official_imdb_id({'external_links':['https://www.imdb.com/title/tt1234567/']}),'tt1234567')
        self.assertIsNone(official_imdb_id({'imdb_id':'tt1234567','related':{'imdb_id':'tt7654321'}}))
        self.assertIsNone(official_imdb_id({'title':'tt1234567','rating':7.0}))

    def test_automatic_connection_rebases_ready_media_instead_of_replaying_old_origin(self):
        hub=Hub.__new__(Hub);hub.lock=threading.RLock();hub.source='reviewed';hub.gap=False
        hub.last_guide_success=time.time();hub.programme=dict(key='current',catalogChannelId=CHANNEL,stopUtc=time.time()+3600)
        hub.sessions={'token':dict(source='reviewed',origin=0,openedMedia=True)}
        class Publisher:
            def snapshot(self):return [dict(timelineStart=i*6,timelineEnd=i*6+6,duration=6) for i in range(20)]
        hub.publisher=Publisher()
        hub.connect_media('token','reviewed',dict(key='current',catalogChannelId=CHANNEL))
        self.assertEqual(hub.sessions['token']['origin'],90)
        self.assertFalse(hub.sessions['token']['openedMedia'])
        with self.assertRaises(ValueError):hub.connect_media('token','reviewed',dict(key='old',catalogChannelId=CHANNEL))

    def test_readiness_uses_full_matched_file_languages_during_silent_gaps(self):
        hub=Hub.__new__(Hub)
        class Engine:
            candidates=[{'tracks':{'en':[]}}]
            reference={'tracks':{'en':[], 'ja':[]}}
        hub.engine=Engine()
        self.assertEqual(hub.caption_status(True),dict(phase='matched',availableLanguages=['en','ja'], cacheHit=False))
        self.assertEqual(hub.caption_status(False)['phase'],'programme_unavailable')

    def test_position_windows_handle_cold_start_and_paused_playheads(self):
        hub=Hub.__new__(Hub);hub.lock=threading.RLock();hub.gap=False;hub.last_guide_success=time.time()
        hub.programme=dict(key='current',stopUtc=time.time()+3600)
        hub.base='https://public.example/';hub.sessions={'token':dict(source='reviewed',origin=0,positionWindow=True)}
        rows=[dict(timelineStart=0,duration=6)]
        windows=[dict(start=i*6,end=i*6+6) for i in range(100)]
        class Publisher:
            def snapshot(self):return list(rows)
        class Engine:
            candidates=[];reference=None
            def windows(self,origin):return windows[:1] if len(rows)==1 else windows
        hub.publisher=Publisher();hub.engine=Engine()
        self.assertEqual(len(hub.response('token')['windows']),1)
        rows.append(dict(timelineStart=6,duration=6))
        old=hub.response('token',60)['windows'];live=hub.response('token',500)['windows']
        self.assertTrue(all(w['end']>30 and w['start']<150 for w in old))
        self.assertTrue(all(w['end']>470 for w in live))
        self.assertLess(len(old),len(windows))

    def test_new_service_preserves_legacy_sessions_and_owns_new_tokens(self):
        import http.server,urllib.request
        from service import serve
        old_requests=[]
        class Legacy(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_GET(self):
                old_requests.append(self.path);data=b'legacy-live-playlist'
                self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
        class NewHub:
            sessions={}
            def response(self,token,position=None):return dict(owner='new')
        old=http.server.ThreadingHTTPServer(('127.0.0.1',0),Legacy)
        threading.Thread(target=old.serve_forever,daemon=True).start()
        ready=threading.Event();servers=[]
        def create(*args,**kwargs):
            server=http.server.ThreadingHTTPServer(*args,**kwargs);servers.append(server);ready.set();return server
        with patch('service.BoundedHTTPServer',create):
            thread=threading.Thread(target=serve,args=(NewHub(),'127.0.0.1',0,old.server_port),daemon=True);thread.start();self.assertTrue(ready.wait(3))
            server=servers[0];token='a'*32
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{server.server_port}/media/{token}/index.m3u8',timeout=3) as response:
                    self.assertEqual(response.read(),b'legacy-live-playlist')
                NewHub.sessions[token]={}
                with urllib.request.urlopen(f'http://127.0.0.1:{server.server_port}/sessions/{token}',timeout=3) as response:
                    self.assertEqual(json.load(response),dict(owner='new'))
                self.assertEqual(len(old_requests),1)
            finally:server.shutdown();server.server_close();thread.join(3);old.shutdown();old.server_close()

    def test_stable_master_bootstraps_only_the_reviewed_owned_feed(self):
        source='https://action-rakuten-tv-uk.fast.rakuten.tv/production-LiveChannel-6065/master.m3u8'
        raw=b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=200\nhigh.m3u8\n'
        with patch('service.public_read',lambda _:raw):self.assertTrue(media_route(source).endswith('/high.m3u8'))
        with patch('service.public_read',lambda _:raw.replace(b'low.m3u8',b'https://unreviewed.example/low.m3u8')):
            with self.assertRaises(ValueError):media_route(source)
    def test_current_catalogue_identity_requires_exact_owned_feed_and_market(self):
        route='https://action-rakuten-tv-uk.fast.rakuten.tv/v1/manifest/key/production-LiveChannel-6065/session/4.m3u8'
        channel=dict(id='current-public-id',countryCode='GB',routes=[dict(url=route)])
        self.assertEqual(pilot_channel(dict(channels=[channel]))[0]['id'],'current-public-id')
        for rows in [[{**channel,'countryCode':'US'}],[{**channel,'routes':[dict(url=route.replace('6065','6066'))]}],[channel,{**channel,'id':'ambiguous'}]]:
            with self.assertRaises(ValueError):pilot_channel(dict(channels=rows))
    def test_possessive_title_release_punctuation_preserves_identity(self):
        self.assertEqual(title_norm("Tom Clancy's Without Remorse"),title_norm('Tom.Clancys.Without.Remorse'))
        self.assertEqual(title_norm('Tom Clancy’s Without Remorse'),title_norm('Tom.Clancys.Without.Remorse'))
        self.assertNotEqual(title_norm("Tom Clancy's Jack Ryan"),title_norm('Tom.Clancys.Without.Remorse'))
    def test_transport_continuity_survives_independent_segment_muxes(self):
        def packet(pid,counter,control=1):
            return bytes([0x47,(pid>>8)&31,pid&255,(control<<4)|counter])+bytes([0xff])*184
        first=packet(256,0)+packet(257,0)+packet(256,1)
        second=packet(256,0)+packet(257,0)+packet(256,0,2)+packet(256,1)
        counters={};a=continuous_counters(first,counters);b=continuous_counters(second,counters)
        self.assertEqual([b[i+3]&15 for i in range(0,len(b),188)],[2,1,2,3])
        self.assertEqual(a,first)
        for i in range(0,len(b),188):self.assertEqual(b[i+4:i+188],second[i+4:i+188])
        with self.assertRaises(ValueError):continuous_counters(b'bad ts',{})

    def test_media_publication_is_ordered_and_readers_use_ready_segments(self):
        with tempfile.TemporaryDirectory() as root:
            from live_media import Collector
            c=Collector('https://public.example/route',root)
            c.rows=[dict(sequence=i,timelineStart=(i-1)*6,timelineEnd=i*6,duration=6,discontinuity=False,sequenceGap=False,keyLine=None) for i in [1,2,3]]
            calls=[];publisher=MediaPublisher(c,'ffmpeg')
            def normalize(row,*args):
                calls.append(row['sequence'])
                if row['sequence']==2:raise ValueError('unusable source segment')
                folder=Path(root)/'normalized';folder.mkdir(exist_ok=True)
                (folder/(str(row['sequence'])+'.ts')).write_bytes(b'x'*188)
                if row['sequence']==3:c.stop.set()
            with patch('live_media.normalize_segment',normalize):publisher.run()
            ready=publisher.snapshot()
            self.assertEqual(calls,[1,2,3])
            self.assertEqual([r['sequence'] for r in ready],[0,1])
            self.assertTrue(ready[-1]['sequenceGap'])

    def test_short_inserts_are_grouped_without_changing_the_clock_or_boundaries(self):
        from live_media import Collector
        with tempfile.TemporaryDirectory() as root:
            c=Collector('https://public.example/route',root)
            c.rows=[dict(sequence=i,timelineStart=i,timelineEnd=i+1,duration=1,
                discontinuity=False,sequenceGap=False,keyLine=None,declaredAd=i<7,
                contentId=None if i<7 else 'movie') for i in range(13)]
            publisher=MediaPublisher(c,'ffmpeg')
            def normalize(row,*args):
                folder=Path(root)/'normalized';folder.mkdir(exist_ok=True)
                (folder/(str(row['sequence'])+'.ts')).write_bytes(bytes([row['sequence']])*188)
                if row['sequence']==12:c.stop.set()
            with patch('live_media.normalize_segment',normalize):publisher.run()
            rows=publisher.snapshot()
            self.assertEqual([(r['timelineStart'],r['timelineEnd'],r['duration']) for r in rows],[(0,6,6),(6,7,1),(7,13,6)])
            self.assertEqual([r['sequence'] for r in rows],[0,1,2])
            self.assertEqual(Path(rows[0]['localPath']).read_bytes(),b''.join(bytes([i])*188 for i in range(6)))

    def test_movie_caid_on_an_insert_does_not_become_episode_identity(self):
        raw = '#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:10\n#EXT-X-ASSET:CAID="m_9"\n#EXTINF:1.0,\nad.ts\n#EXTINF:6.0,extke=Rakutentv:epid=film:ct=m:vt=s\nfilm.ts\n'
        rows = parse_media(raw, 'https://example.org/live')
        self.assertEqual(rows[0]['caid'], 'm_9')
        self.assertIsNone(rows[0]['contentId'])
        self.assertEqual(rows[1]['contentId'], 'film')

    def test_declared_ad_overrides_a_retained_film_id(self):
        raw='#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:1\n#EXT-X-CUE-OUT:30\n#EXTINF:6.0,epid=film\na.ts\n#EXT-X-CUE-IN\n#EXTINF:6.0,epid=film\nb.ts\n'
        rows=parse_media(raw,'https://public.example/live')
        self.assertEqual([r['declaredAd'] for r in rows],[True,False])
        with tempfile.TemporaryDirectory() as root:
            e=Engine('https://public.example/live',dict(movieId='film',title='Film',year=2003),root,None,'ffmpeg',candidates=[])
            e.state='LOCKED';e.k=0;e.verified_asset=rows[0]['asset']
            row={**rows[0],'timelineStart':0,'timelineEnd':6,'sequenceGap':False,'observedWall':time.time()}
            e.collector.rows=[row]
            with patch.object(e.collector.stop,'wait',lambda _:e.collector.stop.set()):e.run()
            self.assertEqual(e.decisions[1]['state'],'SUSPENDED')
            self.assertEqual(e.decisions[1]['tracks'],[])

    def test_subtitle_search_excludes_same_year_tv_episode_with_title_words(self):
        search = '<a href="/subs/1/tv.html">Two and a Half Men 2003 S06 A Jock Strap in Hell</a><a href="/subs/2/film.html">In Hell 2003 BluRay</a>'
        detail = '<a id="download_en" href="/subs/2/a.srt">Download</a><button onclick="generate()">Translate</button>'
        srt = b'1\n00:00:01,000 --> 00:00:02,000\nOne\n\n2\n00:00:03,000 --> 00:00:04,000\nTwo\n\n3\n00:00:05,000 --> 00:00:06,000\nThree\n'
        calls = []
        def read(url):
            calls.append(url)
            return search.encode() if 'index.php?' in url else detail.encode() if url.endswith('.html') else srt
        with tempfile.TemporaryDirectory() as root, patch('subtitle_catalog.read', read):
            result = discover('In Hell', 2003, root)
        self.assertEqual(len(result), 1)
        self.assertEqual(set(result[0]['tracks']), {'en'})
        self.assertFalse(any('tv.html' in url or 'generate' in url for url in calls))

    def test_subtitle_title_admission_rejects_longer_same_prefix_movies(self):
        self.assertTrue(matches_movie_title('The.Prince.2014.1080p.BluRay','The Prince',2014))
        self.assertFalse(matches_movie_title('The.Prince.and.the.108.Demons.2014','The Prince',2014))
        self.assertFalse(matches_movie_title('The.Prince.2019.BluRay','The Prince',2014))
        self.assertFalse(matches_movie_title('The.Green.Prince.2014','The Prince',2014))
        self.assertTrue(matches_movie_title('1917.2019.WEBRip','1917',2019))

    def test_repeated_unmatched_speech_stops_indefinite_sync_hint_and_later_lock_recovers(self):
        with tempfile.TemporaryDirectory() as root:
            c=dict(page='file',tracks={'en':[dict(index=1,start=0,end=2,text='caption')]})
            e=Engine('https://public.example/route',dict(movieId='film',title='Film',year=2003),root,None,'ffmpeg',candidates=[c])
            e.active_asset='movie'
            row=dict(sequence=1,asset='movie',timelineStart=0,timelineEnd=24)
            words=[dict(word='word',start=i,end=i+.5) for i in range(16)]
            with patch('live_engine.transcribe',return_value=words),patch('live_engine.align',return_value=(None,[])):
                for i in range(3):e.analyze([row],row,100,e.generation)
            self.assertTrue(e.acquisition_exhausted)
            hub=Hub.__new__(Hub);hub.engine=e
            self.assertEqual(hub.caption_status(True)['phase'],'unavailable')
            with patch('live_engine.transcribe',return_value=words),patch('live_engine.align',return_value=(1,[dict(cue=1,subtitleStart=100.,asrStart=0.,offset=100.)])):
                e.analyze([row],row,100,e.generation)
            self.assertFalse(e.acquisition_exhausted)
            self.assertEqual(hub.caption_status(True)['phase'],'matched')

    def test_rate_fit_requires_multi_window_evidence_and_rejects_a_clock_step(self):
        rate=(24000/1001)/25
        points=[dict(sourcePts=1000+i*8,subtitleStart=rate*(1000+i*8)+10) for i in range(12)]
        model=fit_clock_rate(points);self.assertAlmostEqual(model['rate'],rate)
        self.assertIsNone(fit_clock_rate(points[:4]))
        plain=[dict(sourcePts=i*8,subtitleStart=i*8+10) for i in range(12)]
        self.assertIsNone(fit_clock_rate(plain))
        self.assertEqual(fit_clock_rate(plain,25/24)['rate'],1.)
        self.assertEqual(fit_clock_rate(plain,24/25)['rate'],1.)
        step=[dict(sourcePts=i*8,subtitleStart=i*8+10-(3 if i>=6 else 0)) for i in range(12)]
        self.assertIsNone(fit_clock_rate(step))

    def test_fast_resume_needs_sufficient_rate_evidence(self):
        points=[dict(sourcePts=100+i*8,subtitleStart=.96*(100+i*8)+10) for i in range(12)]
        self.assertTrue(clock_rate_confident(points,.96,10))
        self.assertFalse(clock_rate_confident(points[:4],.96,10))
        self.assertFalse(clock_rate_confident(points,1,4))

    def test_numpy_timestamps_produce_json_serializable_confidence(self):
        import numpy as np
        points=[dict(sourcePts=np.float64(100+i*8),subtitleStart=np.float64(.96*(100+i*8)+10)) for i in range(12)]
        verified=clock_rate_confident(points,.96,10)
        self.assertIs(type(verified),bool)
        self.assertEqual(json.loads(json.dumps(dict(clockRateVerified=verified))),dict(clockRateVerified=True))

    def test_cue_mapping_applies_rate_and_clips_to_actual_video_segment(self):
        row=dict(timelineStart=20.,timelineEnd=26.)
        cues=[dict(index=1,start=106.,end=107.92,text='existing subtitle')]
        actual=mapped_cues(cues,row,100.,.96,10.)
        self.assertAlmostEqual(actual[0]['start'],20.)
        self.assertAlmostEqual(actual[0]['end'],22.)

    def test_rate_correction_retimes_buffered_cues_without_touching_ads_or_old_clocks(self):
        with tempfile.TemporaryDirectory() as root:
            c=dict(page='existing',tracks={'en':[dict(index=1,start=106,end=107.92,text='caption')]})
            e=Engine('https://public.example/live',dict(movieId='film',title='Film',year=2003),root,None,'ffmpeg',candidates=[c])
            e.reference=c;e.rate=.96;e.k=10;e.generation=2
            base=dict(state='LOCKED',asset='film',clockGeneration=2,pts=100,start=20,end=26,tracks=[])
            e.decisions={1:{**base},2:{**base,'state':'SUSPENDED'},3:{**base,'clockGeneration':1},4:{**base,'asset':'other'},5:{**base,'state':'ACQUIRING'},6:{**base,'state':'ACQUIRING','pts':160}}
            e.retime_decisions('film',20,80)
            self.assertAlmostEqual(e.decisions[1]['tracks'][0]['cues'][0]['start'],20)
            self.assertAlmostEqual(e.decisions[1]['tracks'][0]['cues'][0]['end'],22)
            self.assertEqual(e.decisions[5]['state'],'LOCKED')
            self.assertTrue(e.decisions[5]['tracks'])
            for i in (2,3,4,6):self.assertEqual(e.decisions[i]['tracks'],[])

    def test_fps_drift_is_calibrated_without_repeated_acquisition(self):
        with tempfile.TemporaryDirectory() as root:
            rate=(24000/1001)/25
            c=dict(page='existing',tracks={'en':[dict(index=1,start=0,end=2,text='caption')]})
            e=Engine('https://public.example/live',dict(movieId='film',title='Film',year=2003),root,None,'ffmpeg',candidates=[c]);e.active_asset='film'
            for frame,t in enumerate(range(0,109,18)):
                row=dict(sequence=frame,asset='film',timelineStart=t,timelineEnd=t+18)
                anchors=[dict(cue=frame*3+i,subtitleStart=rate*(1000+t+i*5)+10,asrStart=t+i*5,offset=rate*(1000+t+i*5)+10-t-i*5,words=20) for i in range(3)]
                with patch('live_engine.transcribe',return_value=[]),patch('live_engine.align',return_value=(anchors[1]['offset'],anchors)):
                    e.analyze([row],row,1000+t,e.generation)
            self.assertEqual(e.state,'LOCKED');self.assertAlmostEqual(e.rate,rate)
            self.assertAlmostEqual(e.k,10);self.assertEqual(e.generation,0)

    def test_alignment_requires_multiple_distinct_cues_and_temporal_span(self):
        cues = [dict(index=i+1,start=100+i*5,end=104+i*5,text=text) for i,text in enumerate([
            'bring the heavy wooden chair inside', 'we must leave before the morning comes', 'another traveler waits beneath the bridge'])]
        words = [dict(word=word,start=i*5+j*.25,end=i*5+j*.25+.2,probability=.99)
                 for i,cue in enumerate(cues) for j,word in enumerate(cue['text'].split())]
        offset, anchors = align(words,cues,0)
        self.assertAlmostEqual(offset,100)
        self.assertEqual(len({x['cue'] for x in anchors}),3)
        self.assertIsNone(align(words[:6],cues,0)[0])

    def test_published_english_original_requires_matching_same_page_grid(self):
        search = '<tr><td><a href="/subs/2/film.html">In Hell 2003</a> (translated from English)</td></tr>'
        detail = '<a id="download_es" href="/subs/2/es.srt">Download</a><h3>Original subtitles</h3>' + ''.join('<p dir="auto">'+s+'</p>' for s in ['One','Two','Three']) + '</div>'
        srt = b'1\n00:00:01,000 --> 00:00:02,000\nUno\n\n2\n00:00:03,000 --> 00:00:04,000\nDos\n\n3\n00:00:05,000 --> 00:00:06,000\nTres\n'
        def read(url):
            return search.encode() if 'index.php?' in url else detail.encode() if url.endswith('.html') else srt
        with tempfile.TemporaryDirectory() as root,patch('subtitle_catalog.read',read):
            result=discover('In Hell',2003,root)
        self.assertEqual([c['text'] for c in result[0]['tracks']['en']],['One','Two','Three'])
        self.assertEqual(result[0]['provenance']['en']['clockGridLanguage'],'es')
        detail=detail.replace('<p dir="auto">Three</p>','')
        with tempfile.TemporaryDirectory() as root,patch('subtitle_catalog.read',read):
            self.assertEqual(discover('In Hell',2003,root),[])

    def test_warming_media_is_not_offered_as_ready_playback(self):
        hub = Hub.__new__(Hub)
        hub.lock = threading.RLock(); hub.gap = False
        hub.last_guide_success = time.time()
        hub.programme = dict(key='current', stopUtc=time.time()+3600)
        hub.base = 'https://public.example/'
        hub.sessions = {'token':dict(source='reviewed-source', origin=0)}
        rows = []
        class Publisher:
            def snapshot(self):return list(rows)
        class Engine:
            candidates = []
            reference = None
            def windows(self, origin):return []
        hub.publisher = Publisher(); hub.engine = Engine()
        self.assertFalse(hub.response('token')['playbackReady'])
        rows.extend([dict(timelineStart=0,duration=6),dict(timelineStart=6,duration=6)])
        self.assertFalse(hub.response('token')['playbackReady'])
        rows.extend([dict(timelineStart=12,duration=6),dict(timelineStart=18,duration=6)])
        self.assertTrue(hub.response('token')['playbackReady'])
        hub.gap = True
        self.assertFalse(hub.response('token')['playbackReady'])

    def test_session_requires_current_exact_route_and_programme(self):
        hub = Hub.__new__(Hub); hub.source='https://public.example/route'; hub.gap=False
        hub.last_guide_success=time.time(); hub.programme=dict(key='current',stopUtc=time.time()+3600,catalogChannelId=CHANNEL)
        self.assertTrue(hub.valid_context(hub.source,dict(key='current',catalogChannelId=CHANNEL)))
        self.assertFalse(hub.valid_context('https://private.example/route',None))
        self.assertFalse(hub.valid_context(hub.source,dict(key='previous',catalogChannelId=CHANNEL)))
        hub.last_guide_success-=121
        self.assertFalse(hub.valid_context(hub.source,None))

    def test_ad_clears_cues_and_return_requires_verified_pts_continuity(self):
        for return_pts,verified,expected in [(12.,True,'LOCKED'),(12.,False,'ACQUIRING'),(300.,True,'ACQUIRING')]:
            with self.subTest(return_pts=return_pts,rate_verified=verified),tempfile.TemporaryDirectory() as root:
                candidate=dict(page='existing-file',tracks={'en':[dict(index=1,start=100,end=150,text='Existing subtitle')]})
                e=Engine('https://public.example/route',dict(movieId='film',title='Film',year=2003),root,None,'ffmpeg',candidates=[candidate],synchronous_analysis=True)
                e.collector.rows=[dict(sequence=i,duration=duration,timelineStart=start,timelineEnd=start+duration,
                    contentId=content,caid='m_9',sequenceGap=False,asset='film-asset' if content else 'insert-asset',observedWall=time.time())
                    for i,start,duration,content in [(1,0,6,'film'),(2,6,6,'film'),(3,12,2,None),(4,14,6,'film')]]
                def transcribe(*args):
                    e.collector.stop.set()
                    return []
                with patch('live_engine.clock_rate_confident',return_value=verified),patch('live_engine.media_pts',lambda row,*_: {1:0.,2:6.,4:return_pts}[row['sequence']]),patch('live_engine.transcribe',transcribe),patch('live_engine.align',lambda *args:(100.,[dict(cue=1,subtitleStart=100.,asrStart=0.,offset=100.)])):
                    e.run()
                self.assertEqual(e.decisions[3]['state'],'SUSPENDED')
                self.assertEqual(e.decisions[3]['tracks'],[])
                self.assertEqual(e.decisions[4]['state'],expected)
                if expected!='LOCKED': self.assertEqual(e.decisions[4]['tracks'],[])

    def test_slow_asr_never_blocks_ad_suspension_or_reactivates_stale_calibration(self):
        with tempfile.TemporaryDirectory() as root:
            candidate=dict(page='existing',tracks={'en':[dict(index=1,start=100,end=150,text='Existing subtitle')]})
            e=Engine('https://public.example/route',dict(movieId='film',title='Film',year=2003),root,None,'ffmpeg',candidates=[candidate])
            e.collector.rows=[dict(sequence=i,duration=duration,timelineStart=start,timelineEnd=start+duration,
                contentId=content,caid='m_9',sequenceGap=False,asset='film' if content else 'insert',observedWall=time.time())
                for i,start,duration,content in [(1,0,6,'film'),(2,6,6,'film'),(3,12,1,None)]]
            started=threading.Event();release=threading.Event()
            def slow(*args):
                started.set();release.wait(2);return []
            with patch('live_engine.media_pts',lambda row,*_:row['timelineStart']),patch('live_engine.transcribe',slow),patch('live_engine.align',lambda *args:(100.,[dict(cue=1,subtitleStart=100.,asrStart=0.,offset=100.)])):
                controller=threading.Thread(target=e.run);controller.start()
                self.assertTrue(started.wait(1))
                deadline=time.monotonic()+1
                while 3 not in e.decisions and time.monotonic()<deadline:time.sleep(.01)
                self.assertEqual(e.decisions[3]['tracks'],[])
                self.assertEqual(e.decisions[3]['state'],'SUSPENDED')
                release.set();e.collector.stop.set();controller.join(2);e.analysis_thread.join(2)
                self.assertIsNone(e.k)
                self.assertIsNone(e.reference)


if __name__=='__main__':
    unittest.main()
