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
from pathlib import Path
import re
import shutil
import subprocess
import threading
import time
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen
import uuid

from live_engine import Engine
from live_media import playlist, MediaPublisher
from subtitle_catalog import LANGUAGES

CHANNEL = 'channel-b842f9cdd43743693f77fc81'
NODE = 'https://bobtv.briconbric.com'


def public_read(url):
    with urlopen(Request(url, headers={'User-Agent': 'BobTV-EPG-Validator/1.0'}), timeout=15) as response:
        raw = response.read(32 * 1024 * 1024 + 1)
    if len(raw) > 32 * 1024 * 1024:
        raise ValueError('public_response_limit')
    return raw


def snapshot(kind):
    manifest = json.loads(public_read(NODE + '/api/v1/' + kind + '/manifest'))
    path = manifest['snapshotUrl']
    if not path.startswith('/api/v1/' + kind + '/snapshots/'):
        raise ValueError('unreviewed_snapshot_url')
    raw = public_read(NODE + path)
    if hashlib.sha256(raw).hexdigest() != manifest['sha256']:
        raise ValueError('public_snapshot_checksum')
    decoded = gzip.decompress(raw)
    if len(decoded) > 32 * 1024 * 1024:
        raise ValueError('public_snapshot_decoded_limit')
    return json.loads(decoded)


def current_guide():
    now = int(time.time())
    catalog, guide = snapshot('channel-catalog'), snapshot('epg')
    channel = next(c for c in catalog['channels'] if c['id'] == CHANNEL)
    route = next(r['url'] for r in channel['routes'] if urlsplit(r['url']).hostname == 'action-rakuten-tv-uk.fast.rakuten.tv'
                 and '/production-LiveChannel-6065/' in r['url'])
    programmes = [p for p in guide['programmes'] if p['channelId'] == CHANNEL and p['startUtc'] <= now < p['stopUtc']]
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
    return route, dict(key=key, catalogChannelId=CHANNEL, programmeSourceId=p['sourceId'],
        originalChannelId=p['originalChannelId'], sourceEventId=facts['sourceEventId'], movieId=movie,
        title=metadata['title'], year=metadata['year'], numericalMovieId=metadata['numerical_id'],
        marketCode='uk', serviceId=6065, startUtc=p['startUtc'], stopUtc=p['stopUtc'], clockIsSubtitleOffset=False)


class Hub:
    def __init__(self, root, model, ffmpeg, base):
        self.root, self.model, self.ffmpeg, self.base = Path(root), model, ffmpeg, base.rstrip('/') + '/'
        self.root.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock(); self.sessions = {}; self.engine = None
        self.publisher = None
        self.source, self.programme = current_guide(); self.last_guide_success = time.time()
        self.gap = False
        threading.Thread(target=self.maintain, daemon=True).start()

    def valid_context(self, source, programme):
        if source != self.source or self.gap or time.time() > self.programme['stopUtc'] or time.time() - self.last_guide_success > 120:
            return False
        return programme is None or (isinstance(programme, dict) and programme.get('key') == self.programme['key']
                                     and programme.get('catalogChannelId') == CHANNEL)

    def create(self, source, context, language):
        with self.lock:
            if not self.valid_context(source, context):
                raise ValueError('exact_current_public_route_required')
            if len(self.sessions) >= 4:
                raise RuntimeError('pilot_capacity')
            if self.engine is None:
                root = self.root / uuid.uuid4().hex
                self.engine = Engine(source, self.programme, root, self.model, self.ffmpeg, preferred_language=language)
                self.engine.start()
                self.publisher=MediaPublisher(self.engine.collector,self.ffmpeg)
                threading.Thread(target=self.publisher.run,daemon=True).start()
            rows = self.engine.collector.snapshot()
            chosen = [r for r in rows if r['timelineEnd'] > (rows[-1]['timelineEnd'] - 30)] if rows else []
            token = uuid.uuid4().hex
            self.sessions[token] = dict(origin=chosen[0]['timelineStart'] if chosen else 0,
                                        lastAccess=time.time(), source=source, language=language,openedMedia=False)
            return token

    def response(self, token):
        with self.lock:
            session = self.sessions[token]; session['lastAccess'] = time.time()
            usable = not self.gap and time.time() - self.last_guide_success <= 120 and time.time() < self.programme['stopUtc']
            return dict(session=token, source=session['source'], programmeKey=self.programme['key'] if usable else None,
                        playbackUrl=self.base + 'media/' + token + '/index.m3u8',
                        mediaClockOrigin=session['origin'],
                        windows=self.engine.windows(session['origin']) if usable else [])

    def maintain(self):
        next_guide = time.monotonic() + 25
        while True:
            time.sleep(1)
            with self.lock:
                for token in list(self.sessions):
                    if time.time() - self.sessions[token]['lastAccess'] > 180:
                        del self.sessions[token]
                if not self.sessions and self.engine is not None:
                    self.engine.collector.stop.set(); self.engine.controller_stop.set()
                    self.engine = None; self.publisher=None
            if time.monotonic() < next_guide:
                continue
            next_guide = time.monotonic() + 25
            try:
                source, programme = current_guide()
                with self.lock:
                    changed = programme['key'] != self.programme['key']
                    if source != self.source:
                        # A catalogue route change requires a new explicit playback session.
                        self.gap = True
                        continue
                    self.programme, self.last_guide_success, self.gap = programme, time.time(), False
                    if changed and self.engine is not None:
                        old = self.engine; old.controller_stop.set()
                        self.engine = Engine(source, programme, old.root / 'programme-' / uuid.uuid4().hex,
                                             self.model, self.ffmpeg, preferred_language=next(iter(self.sessions.values()))['language'])
                        self.engine.collector = old.collector
                        self.engine.last_sequence = old.collector.snapshot()[-1]['sequence'] if old.collector.snapshot() else -1
                        self.engine.start(collect=False)
            except Exception:
                with self.lock:
                    self.gap = True
            # Inactive private media is deleted after two hours;
            # audit receipts can be exported before cleanup by the test runner.
            with self.lock:
                active = self.engine.collector.root.parts if self.engine else ()
                for folder in self.root.iterdir():
                    if folder.is_dir() and folder.name not in active and time.time() - folder.stat().st_mtime > 7200:
                        shutil.rmtree(folder)


def serve(hub, host, port):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, data, content_type='application/json', status=200, cache=False):
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
            if not 0 < length <= 16384:
                raise ValueError('request_limit')
            return json.loads(self.rfile.read(length))

        def do_POST(self):
            try:
                body = self.body(); path = urlsplit(self.path).path
                if path == '/sessions':
                    language = body.get('language', 'en')
                    if language not in LANGUAGES:
                        raise ValueError('unsupported_language')
                    token = hub.create(body.get('source'), body.get('programme'), language)
                else:
                    match = re.fullmatch(r'/sessions/([a-f0-9]{32})/programme', path)
                    if not match or not hub.valid_context(body.get('source'), body.get('programme')):
                        raise ValueError('current_programme_required')
                    token = match[1]
                self.send(json.dumps(hub.response(token), ensure_ascii=False).encode())
            except RuntimeError:
                self.send(b'{"error":"pilot_capacity"}', status=503)
            except (ValueError, KeyError, TypeError):
                self.send(b'{"error":"unsupported_or_stale_programme"}', status=404)

        def do_GET(self):
            try:
                path = urlsplit(self.path).path
                if path == '/health':
                    return self.send(json.dumps(dict(status='ready', pilot='rakuten-uk-6065',
                                                     activeSessions=len(hub.sessions))).encode())
                match = re.fullmatch(r'/sessions/([a-f0-9]{32})', path)
                if match:
                    return self.send(json.dumps(hub.response(match[1]), ensure_ascii=False).encode())
                match = re.fullmatch(r'/media/([a-f0-9]{32})/(index\.m3u8|segments/(?:[0-9]+\.ts|key-[a-f0-9]{20}\.bin))', path)
                if not match:
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
                media=collector.root/'normalized'/filename
                return self.send(media.read_bytes(),
                                 'video/mp2t' if filename.endswith('.ts') else 'application/octet-stream', cache=True)
            except (subprocess.SubprocessError, ValueError):
                self.send(b'{"error":"media_clock_conversion_failed"}', status=502)
            except (KeyError, OSError, StopIteration):
                self.send(b'{"error":"not_found"}', status=404)
    ThreadingHTTPServer((host, port), Handler).serve_forever()


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--root', required=True); parser.add_argument('--model-root', required=True)
    parser.add_argument('--base', required=True); parser.add_argument('--port', type=int, default=8921)
    args = parser.parse_args()
    import imageio_ffmpeg
    from faster_whisper import WhisperModel
    model = WhisperModel('tiny.en', device='cpu', compute_type='int8', cpu_threads=2,
                         download_root=args.model_root, local_files_only=True)
    ffmpeg = shutil.which('ffmpeg') or imageio_ffmpeg.get_ffmpeg_exe()
    hub = Hub(args.root, model, ffmpeg, args.base)
    serve(hub, '127.0.0.1', args.port)


if __name__ == '__main__':
    main()
