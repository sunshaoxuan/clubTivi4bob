"""Pilot live subtitle service backed by current public EPG and real live media.

The sole enabled pilot is the exact reviewed Action Movies UK route. The service
retrieves existing subtitle files and runs local ASR for alignment only. Media
and subtitle caches are private, bounded to the active viewing session.
"""
import argparse
import gzip
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import http.client
from pathlib import Path
import re
import shutil
import subprocess
import threading
import time
from urllib.parse import urlencode, urlsplit, urljoin, parse_qs
from urllib.request import Request, urlopen
import uuid

from live_engine import Engine
from live_media import playlist, MediaPublisher
from subtitle_catalog import LANGUAGES
from subtitle_cache import SubtitleCache

CHANNEL = 'channel-b842f9cdd43743693f77fc81'
NODE = 'https://bobtv.briconbric.com'


def public_read(url):
    with urlopen(Request(url, headers={'User-Agent': 'BobTV-EPG-Validator/1.0'}), timeout=15) as response:
        raw = response.read(32 * 1024 * 1024 + 1)
    if len(raw) > 32 * 1024 * 1024:
        raise ValueError('public_response_limit')
    return raw


_SNAPSHOT_CACHE = {}
_SNAPSHOT_LOCK = threading.RLock()

def snapshot(kind):
    manifest = json.loads(public_read(NODE + '/api/v1/' + kind + '/manifest'))
    path = manifest['snapshotUrl']
    if not path.startswith('/api/v1/' + kind + '/snapshots/'):
        raise ValueError('unreviewed_snapshot_url')
    with _SNAPSHOT_LOCK:
        cached=_SNAPSHOT_CACHE.get(kind)
        if cached and cached[0]==manifest['sha256']:return cached[1]
    raw = public_read(NODE + path)
    if hashlib.sha256(raw).hexdigest() != manifest['sha256']:
        raise ValueError('public_snapshot_checksum')
    decoded = gzip.decompress(raw)
    if len(decoded) > 32 * 1024 * 1024:
        raise ValueError('public_snapshot_decoded_limit')
    value=json.loads(decoded)
    with _SNAPSHOT_LOCK:_SNAPSHOT_CACHE[kind]=(manifest['sha256'],value)
    return value


def official_imdb_id(metadata):
    # Admit only identifiers from the validated official movie record.
    found = set()
    def visit(value, key=''):
        if isinstance(value, dict):
            for name, item in value.items(): visit(item, name.lower())
        elif isinstance(value, list):
            for item in value: visit(item, key)
        elif isinstance(value, str):
            if 'imdb' in key and re.fullmatch(r'tt[0-9]{7,10}', value): found.add(value)
            try: parts = urlsplit(value)
            except ValueError: return
            if parts.hostname in {'imdb.com','www.imdb.com'}:
                match = re.fullmatch(r'/title/(tt[0-9]{7,10})/?', parts.path)
                if match: found.add(match[1])
    visit(metadata)
    return next(iter(found)) if len(found) == 1 else None


def current_guide():
    now = int(time.time())
    catalog, guide = snapshot('channel-catalog'), snapshot('epg')
    channel,route = pilot_channel(catalog)
    programmes = [p for p in guide['programmes'] if p['channelId'] == channel['id'] and p['startUtc'] <= now < p['stopUtc']]
    if len(programmes) != 1:
        raise ValueError('unambiguous_current_programme_required')
    p = programmes[0]; facts = p['provenance']; movie = facts.get('movieId')
    if p['sourceId'] != 'rakuten-uk-official-v1' or facts.get('serviceId') != 6065 or not re.fullmatch(r'[a-z0-9-]{1,200}', movie or ''):
        raise ValueError('reviewed_movie_identity_required')
    metadata = json.loads(public_read('https://gizmo.rakuten.tv/v3/movies/' + movie + '?' + urlencode(dict(
        classification_id=18, device_identifier='web', locale='en', market_code='uk'))))['data']
    if metadata['id'] != movie or not isinstance(metadata.get('year'), int):
        raise ValueError('official_movie_identity_mismatch')
    key = f"{p['sourceId']}:{p['originalChannelId']}:{facts['sourceEventId']}:{p['stopUtc']}:{movie}"
    return route, dict(key=key, catalogChannelId=channel['id'], programmeSourceId=p['sourceId'],
        originalChannelId=p['originalChannelId'], sourceEventId=facts['sourceEventId'], movieId=movie,
        title=metadata['title'], year=metadata['year'], numericalMovieId=metadata['numerical_id'],
        imdbId=official_imdb_id(metadata), marketCode='uk', serviceId=6065, startUtc=p['startUtc'], stopUtc=p['stopUtc'], clockIsSubtitleOffset=False)


def reviewed_pilot_source(source):
    if not isinstance(source,str):return False
    uri=urlsplit(source)
    return (uri.scheme=='https' and uri.hostname=='action-rakuten-tv-uk.fast.rakuten.tv'
            and uri.port in (None,443) and uri.username is None and uri.password is None
            and re.fullmatch(r'/v1/(?:master|manifest)/[^/]+/production-(?:LiveChannel-6065|hls-aes128-rtv-6065-playout)/(?:[^/]+/)*[^/]+\.m3u8',uri.path) is not None)


def pilot_channel(catalog):
    """Bind the current public identity by the reviewed provider feed, not a title."""
    matches=[]
    for channel in catalog['channels']:
        if channel.get('countryCode')!='GB':continue
        routes=[r['url'] for r in channel['routes'] if reviewed_pilot_source(r['url'])]
        if routes:matches.append((channel,routes[0]))
    if len(matches)!=1:raise ValueError('unambiguous_reviewed_public_feed_required')
    return matches[0]


def media_route(source):
    """Bootstrap a fresh provider media session from its stable public master."""
    body=public_read(source).decode()
    if '#EXT-X-STREAM-INF:' not in body:return source
    variants=[];bandwidth=None
    for line in body.splitlines():
        if line.startswith('#EXT-X-STREAM-INF:'):
            found=re.search(r'(?:^|,)BANDWIDTH=(\d+)',line.split(':',1)[1]);bandwidth=int(found[1]) if found else 0
        elif line and not line.startswith('#') and bandwidth is not None:
            uri=urljoin(source,line);parts=urlsplit(uri)
            if parts.scheme!='https' or parts.hostname!='action-rakuten-tv-uk.fast.rakuten.tv' or not re.search(r'/production-(?:LiveChannel-6065|hls-aes128-rtv-6065-playout)/',parts.path):
                raise ValueError('unreviewed_media_variant')
            variants.append((bandwidth,uri));bandwidth=None
    if not variants:raise ValueError('reviewed_media_variant_required')
    return max(variants)[1]


class Hub:
    def __init__(self, root, model, ffmpeg, base, subtitle_cache=None, prewarm=False):
        self.root, self.model, self.ffmpeg, self.base = Path(root), model, ffmpeg, base.rstrip('/') + '/'
        self.root.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock(); self.sessions = {}; self.engine = None
        self.publisher = None
        self.subtitle_cache = subtitle_cache
        self.prewarm = prewarm
        self.next_bootstrap = 0
        self.source, self.programme = current_guide(); self.last_guide_success = time.time()
        self.gap = False
        threading.Thread(target=self.maintain, daemon=True).start()

    def valid_context(self, source, programme):
        if source != self.source or self.gap or time.time() > self.programme['stopUtc'] or time.time() - self.last_guide_success > 120:
            return False
        return programme is None or (isinstance(programme, dict) and programme.get('key') == self.programme['key']
                                     and programme.get('catalogChannelId') == self.programme['catalogChannelId'])

    def ensure_engine(self, language='en'):
        if self.engine is not None:return
        root=self.root/uuid.uuid4().hex
        self.engine=Engine(media_route(self.source),self.programme,root,self.model,self.ffmpeg,
                           preferred_language=language,subtitle_cache=self.subtitle_cache)
        self.engine_started=time.monotonic()
        self.engine.start()
        self.publisher=MediaPublisher(self.engine.collector,self.ffmpeg)
        threading.Thread(target=self.publisher.run,daemon=True).start()

    def expire_and_prewarm(self):
        with self.lock:
            for token in list(self.sessions):
                if time.time()-self.sessions[token]['lastAccess']>180:del self.sessions[token]
            if not self.sessions and self.engine is not None and not self.prewarm:
                self.engine.collector.stop.set();self.engine.controller_stop.set()
                self.engine=None;self.publisher=None
            if self.prewarm and not self.sessions and self.engine is not None:
                collector=self.engine.collector
                rows=collector.snapshot() if hasattr(collector,'snapshot') else []
                stale=(time.time()-rows[-1].get('downloadedWall',time.time())>45) if rows else (time.monotonic()-getattr(self,'engine_started',time.monotonic())>45)
                if stale:
                    collector.stop.set();self.engine.controller_stop.set()
                    self.engine=None;self.publisher=None
            if (self.prewarm and self.engine is None and time.monotonic() >= self.next_bootstrap
                    and self.valid_context(self.source,None)):
                self.ensure_engine()

    def handover(self, programme):
        old=self.engine;old.controller_stop.set()
        language=next(iter(self.sessions.values()),{'language':'en'})['language']
        self.engine=Engine(old.collector.source,programme,old.collector.root/'programmes'/uuid.uuid4().hex,
                           self.model,self.ffmpeg,preferred_language=language,subtitle_cache=self.subtitle_cache)
        self.engine.collector=old.collector
        rows=old.collector.snapshot()
        self.engine.last_sequence=rows[-1]['sequence'] if rows else -1
        self.engine.start(collect=False)

    def create(self, source, context, language, features=()):
        with self.lock:
            if not self.valid_context(source, context):
                raise ValueError('exact_current_public_route_required')
            if len(self.sessions) >= 4:
                raise RuntimeError('pilot_capacity')
            self.ensure_engine(language)
            rows = self.publisher.snapshot()
            chosen = [r for r in rows if r['timelineEnd'] > (rows[-1]['timelineEnd'] - 30)] if rows else []
            token = uuid.uuid4().hex
            self.sessions[token] = dict(origin=chosen[0]['timelineStart'] if chosen else 0,
                                        lastAccess=time.time(), source=source, language=language,openedMedia=False,
                                        positionWindow='positionWindowV1' in features)
            return token

    def connect_media(self, token, source, programme):
        with self.lock:
            if not self.valid_context(source, programme) or self.sessions[token]['source'] != source:
                raise ValueError('current_programme_required')
            rows = self.publisher.snapshot()
            chosen = [r for r in rows if r['timelineEnd'] > rows[-1]['timelineEnd']-30] if rows else []
            if sum(r['duration'] for r in chosen) < 24:
                raise RuntimeError('media_not_ready')
            self.sessions[token].update(origin=chosen[0]['timelineStart'], openedMedia=False, lastAccess=time.time())

    def caption_status(self, usable):
        engine = self.engine
        if not usable:
            return dict(phase='programme_unavailable', availableLanguages=[])
        if getattr(engine, 'discovery_error', False):
            return dict(phase='service_unavailable', availableLanguages=[])
        if engine.candidates is None:
            return dict(phase='searching', availableLanguages=[])
        if not engine.candidates or (getattr(engine, 'acquisition_exhausted', False) and not engine.reference):
            return dict(phase='unavailable', availableLanguages=[])
        # Availability describes the complete matched file, including silent
        # gaps. A window with no spoken cue does not mean the track is missing.
        reference = engine.reference
        languages = sorted(reference['tracks']) if reference else []
        return dict(phase='matched' if reference else 'synchronizing',
                    availableLanguages=languages, cacheHit=bool(engine.candidates and all(c.get('cacheHit') for c in engine.candidates)))

    def response(self, token, position=None):
        with self.lock:
            session = self.sessions[token]; session['lastAccess'] = time.time()
            usable = not self.gap and time.time() - self.last_guide_success <= 120 and time.time() < self.programme['stopUtc']
            rows = [r for r in self.publisher.snapshot() if r['timelineStart'] >= session['origin']]
            fresh = not rows or time.time()-rows[-1].get('downloadedWall',time.time())<=45
            ready = usable and fresh and sum(r['duration'] for r in rows) >= 24
            windows = self.engine.windows(session['origin']) if usable and fresh else []
            if session.get('positionWindow') and windows:
                center = position if position is not None else max(0, max(w['end'] for w in windows)-24)
                if not math.isfinite(center) or center < 0:
                    raise ValueError('invalid_playback_position')
                windows = [w for w in windows if w['end'] > center-30 and w['start'] < center+90]
            return dict(session=token, source=session['source'], playbackReady=ready, programmeKey=self.programme['key'] if usable else None,
                        playbackUrl=self.base + 'media/' + token + '/index.m3u8',
                        mediaClockOrigin=session['origin'],
                        subtitleStatus=self.caption_status(usable) if fresh else dict(phase='service_unavailable',availableLanguages=[]),
                        windows=windows)

    def maintain(self):
        next_guide = time.monotonic() + 25
        while True:
            time.sleep(1)
            try:self.expire_and_prewarm()
            except Exception:
                with self.lock:self.next_bootstrap=time.monotonic()+15
            if time.monotonic() < next_guide:
                continue
            next_guide = time.monotonic() + 25
            try:
                source, programme = current_guide()
                with self.lock:
                    changed = (programme['key'] != self.programme['key'] or programme['catalogChannelId'] != self.programme['catalogChannelId'])
                    if source != self.source:
                        # A catalogue route change requires a new explicit playback session.
                        self.gap = True
                        continue
                    self.programme, self.last_guide_success, self.gap = programme, time.time(), False
                    if changed and self.engine is not None:
                        self.handover(programme)
            except Exception:
                with self.lock:
                    self.gap = True
            # Inactive private media is deleted after two hours;
            # audit receipts can be exported before cleanup by the test runner.
            with self.lock:
                if self.engine:
                    programmes=self.engine.collector.root/'programmes'
                    if programmes.exists():
                        for folder in programmes.iterdir():
                            if folder.is_dir() and folder!=self.engine.root and time.time()-folder.stat().st_mtime>7200:
                                shutil.rmtree(folder)
                active = self.engine.collector.root.parts if self.engine else ()
                for folder in self.root.iterdir():
                    if folder.is_dir() and folder.name not in active and time.time() - folder.stat().st_mtime > 7200:
                        shutil.rmtree(folder)


def serve(hub, host, port, legacy_port=None):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, data, content_type='application/json', status=200, cache=False):
            if hasattr(hub,'traffic'):hub.traffic['sentJsonBytes']+=len(data)
            self.send_response(status); self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'public,max-age=60' if cache else 'no-store')
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def body(self):
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 65536:
                raise ValueError('request_limit')
            if hasattr(hub,'traffic'):hub.traffic['receivedJsonBytes']+=length
            return json.loads(self.rfile.read(length))

        def legacy(self, path, body=None):
            match = re.fullmatch(r'/(?:sessions|media)/([a-f0-9]{32})(?:/(?:programme|connect|index\.m3u8|segments/[0-9]+\.ts))?', path)
            if legacy_port is None or not match or match[1] in hub.sessions:
                return False
            connection = http.client.HTTPConnection('127.0.0.1', legacy_port, timeout=10)
            try:
                raw = json.dumps(body).encode() if body is not None else None
                connection.request('POST' if body is not None else 'GET', self.path, body=raw,
                                   headers={'Content-Type':'application/json'})
                response = connection.getresponse()
                data = response.read(16*1024*1024+1)
                if len(data)>16*1024*1024: raise ValueError('legacy_response_limit')
                self.send(data, response.getheader('Content-Type','application/json'), response.status)
            except (OSError, http.client.HTTPException):
                self.send(b'{"error":"expired_session"}', status=404)
            finally: connection.close()
            return True

        def do_POST(self):
            try:
                body = self.body(); path = urlsplit(self.path).path
                if self.legacy(path, body): return
                if path == '/sessions':
                    language = body.get('language', 'en')
                    if language not in LANGUAGES:
                        raise ValueError('unsupported_language')
                    token = hub.create(body.get('source'), body.get('programme'), language, body.get('features', ()))
                else:
                    match = re.fullmatch(r'/sessions/([a-f0-9]{32})/(programme|connect|observations)', path)
                    if not match or not hub.valid_context(body.get('source'), body.get('programme')):
                        raise ValueError('current_programme_required')
                    token = match[1]
                    if match[2] == 'connect':
                        if getattr(hub,'client_only',False):raise ValueError('text_only_session')
                        hub.connect_media(token, body.get('source'), body.get('programme'))
                    if match[2] == 'observations': hub.ingest(token,body)
                self.send(json.dumps(hub.response(token), ensure_ascii=False).encode())
            except RuntimeError:
                self.send(b'{"error":"pilot_capacity"}', status=503)
            except OSError as error:
                if getattr(hub,'client_only',False):
                    hub.event('programme_lookup_unavailable',errorType=type(error).__name__)
                self.send(b'{"error":"programme_lookup_unavailable"}', status=503)
            except (ValueError, KeyError, TypeError) as error:
                if getattr(hub,'client_only',False):
                    reason=str(error)
                    allowed={'current_programme_required','stale_programme','invalid_clock_observation','invalid_epoch','replayed_observation','word_limit','invalid_word','stale_epoch','client_clock_required','unsupported_language'}
                    hub.event('client_request_rejected',errorType=type(error).__name__,reason=reason if reason in allowed else 'invalid_request',guideGap=hub.gap,lastGoodGuideAgeSeconds=round(time.time()-hub.last_guide_success,3))
                self.send(b'{"error":"unsupported_or_stale_programme"}', status=404)

        def do_GET(self):
            try:
                path = urlsplit(self.path).path
                if self.legacy(path): return
                if path == '/health':
                    return self.send(json.dumps(dict(status='ready', pilot='epg-bound-channels', activeChannels=len(getattr(hub,'channels',{})), programmeDiscovery='public-epg',
                                                     activeSessions=len(hub.sessions), prewarmEnabled=getattr(hub,'prewarm',False),
                                                     engineRunning=getattr(hub,'engine',None) is not None,
                                                     clientOnly=bool(getattr(hub,'client_only',False)),
                                                     traffic=getattr(hub,'traffic',None),
                                                     programmeTitle=getattr(hub,'programme',{}).get('title'),
                                                     alignmentState=getattr(getattr(hub,'engine',None),'state','IDLE'),
                                                     clockRate=float(getattr(getattr(hub,'engine',None),'rate',1)),
                                                     clockRateVerified=bool(getattr(getattr(hub,'engine',None),'rate_verified',False)))).encode())
                match = re.fullmatch(r'/sessions/([a-f0-9]{32})', path)
                if match:
                    position=parse_qs(urlsplit(self.path).query).get('position',[None])[0]
                    position=float(position) if position is not None else None
                    return self.send(json.dumps(hub.response(match[1], position), ensure_ascii=False).encode())
                match = re.fullmatch(r'/media/([a-f0-9]{32})/(index\.m3u8|segments/(?:[0-9]+\.ts|key-[a-f0-9]{20}\.bin))', path)
                if not match or getattr(hub,'client_only',False):
                    raise KeyError()
                token, resource = match[1], match[2]
                with hub.lock:
                    session = hub.sessions[token]; session['lastAccess'] = time.time(); collector = hub.engine.collector;publisher=hub.publisher
                if resource == 'index.m3u8':
                    rows = [r for r in publisher.snapshot() if r['timelineStart'] >= session['origin']]
                    deadline = time.monotonic() + 12
                    while (not rows or (not session['openedMedia'] and sum(r['duration'] for r in rows)<24)) and time.monotonic() < deadline and not collector.stop.is_set():
                        time.sleep(.1)
                        rows = [r for r in publisher.snapshot() if r['timelineStart'] >= session['origin']]
                    if not rows:
                        return self.send(b'{"error":"acquiring_media"}', status=503)
                    session['openedMedia']=True
                    content = playlist(rows, uri=lambda r: 'segments/' + Path(r['localPath']).name, local_keys=False)
                    return self.send(content.encode(), 'application/vnd.apple.mpegurl')
                filename = resource.split('/')[-1]
                if not filename.endswith('.ts'):
                    raise KeyError()
                sequence=int(filename[:-3]);row=next(r for r in publisher.snapshot() if r['sequence']==sequence)
                media=Path(row['localPath'])
                return self.send(media.read_bytes(),
                                 'video/mp2t' if filename.endswith('.ts') else 'application/octet-stream', cache=True)
            except (subprocess.SubprocessError, ValueError):
                self.send(b'{"error":"media_clock_conversion_failed"}', status=502)
            except (KeyError, OSError, StopIteration):
                self.send(b'{"error":"not_found"}', status=404)
    ThreadingHTTPServer((host, port), Handler).serve_forever()


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--root', required=True); parser.add_argument('--model-root', required=True)
    parser.add_argument('--subtitle-cache-root', default='/var/lib/bobtv/resource-cache/subtitles'); parser.add_argument('--base', required=True); parser.add_argument('--port', type=int, default=8922); parser.add_argument('--legacy-port', type=int); parser.add_argument('--prewarm', action='store_true'); parser.add_argument('--client-only', action='store_true')
    args = parser.parse_args()
    if args.client_only:
        from multi_client_clock import MultiTextHub
        hub=MultiTextHub(args.root,SubtitleCache(args.subtitle_cache_root,legacy_roots=['/var/lib/bobtv/live-subtitles']))
        return serve(hub,'127.0.0.1',args.port)
    import imageio_ffmpeg
    from faster_whisper import WhisperModel
    model = WhisperModel('tiny.en', device='cpu', compute_type='int8', cpu_threads=2,
                         download_root=args.model_root, local_files_only=True)
    ffmpeg = shutil.which('ffmpeg') or imageio_ffmpeg.get_ffmpeg_exe()
    hub = Hub(args.root, model, ffmpeg, args.base, SubtitleCache(args.subtitle_cache_root, legacy_roots=['/var/lib/bobtv/live-subtitles']), prewarm=args.prewarm)
    serve(hub, '127.0.0.1', args.port, args.legacy_port)


if __name__ == '__main__':
    main()
