"""Bounded server-only egress for reviewed TV resources and named integrations.

No arbitrary URL proxy, no CONNECT, no private addresses, no client redirects.
Playback keeps canonical route identities; HLS child capabilities are signed.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import sqlite3
import threading
import tempfile
import time
import urllib.error
import urllib.request
import zlib
from collections import OrderedDict
from pathlib import Path
from urllib.parse import urlencode, urljoin, urlsplit

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import Response, StreamingResponse, FileResponse
from starlette.background import BackgroundTask
from starlette.concurrency import run_in_threadpool

from catalog_inventory import DATA
from network_routes import _secret
from process_channel_inventory import _HTTPHandler, _HTTPSHandler
from route_identity import canonical_route_url
from dash_relay import rewrite_mpd, expand_template

router = APIRouter(prefix='/api/v1/egress')
ORIGIN = 'https://bobtv.briconbric.com'
MAX_PLAYLIST = 2 * 1024 * 1024
MAX_DATA = 16 * 1024 * 1024
MAX_EPG = 64 * 1024 * 1024
SLOTS = threading.BoundedSemaphore(16)
SMALL_SLOTS = threading.BoundedSemaphore(4)
_epg_lock = threading.Lock()
_lock = threading.Lock()
_rates = OrderedDict()
_cache = OrderedDict()
_cache_bytes = 0
EPG = {'https://epg.zsdc.eu.org/t.xml.gz', 'https://epg.112114.xyz/pp.xml'}
DATA_HOSTS = {
    'api.themoviedb.org': ('/3/',),
    'api.trakt.tv': ('/',),
    'geocoding-api.open-meteo.com': ('/v1/search',),
    'api.open-meteo.com': ('/v1/forecast',),
    'api.real-debrid.com': ('/rest/1.0/',),
    'api.alldebrid.com': ('/v4/',),
    'www.premiumize.me': ('/api/',),
    'debrid-link.com': ('/api/v2/',),
    'offcloud.com': ('/api/',),
    'api.put.io': ('/v2/',),
    'torrentio.strem.fun': ('/stream/',),
}
REQUEST_HEADERS = {'user-agent', 'accept', 'accept-language', 'range',
    'if-range', 'authorization', 'content-type', 'trakt-api-key',
    'trakt-api-version', 'referer', 'origin'}
RESPONSE_HEADERS = {'content-type', 'content-range', 'accept-ranges',
    'content-encoding', 'etag', 'last-modified'}


def public_url(url):
    if not isinstance(url, str) or not 1 <= len(url) <= 4096 or any(ord(c) <= 32 for c in url):
        raise ValueError('Invalid public URL')
    parsed = urlsplit(url)
    host = (parsed.hostname or '').lower()
    if parsed.scheme not in ('http', 'https') or not host or parsed.username or parsed.password or parsed.fragment:
        raise ValueError('Invalid public URL')
    if host == 'localhost' or host.endswith(('.local', '.internal', '.localhost')) or '.' not in host and ':' not in host:
        raise ValueError('Private hostname')
    if parsed.port is not None and not 1 <= parsed.port <= 65535: raise ValueError('Invalid port')
    return parsed


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl): return None


def upstream(url, headers=None, method='GET', body=None):
    """DNS is checked and pinned by the connection, with normal TLS/SNI checks."""
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
        NoRedirect(), _HTTPHandler(), _HTTPSHandler())
    headers = {'User-Agent': 'BobTV-Gateway/1.0', 'Accept-Encoding': 'identity', **(headers or {})}
    for attempt in range(5):
        public_url(url)
        try:
            response = opener.open(urllib.request.Request(url, data=body,
                method=method, headers=headers), timeout=12)
        except urllib.error.HTTPError as exc:
            response = exc
        if response.code not in (301, 302, 303, 307, 308): return response
        location = response.headers.get('Location')
        response.close()
        if not location or attempt == 4: raise ValueError('Invalid redirect')
        following = urljoin(url, location)
        if any(key.lower() in ('authorization', 'trakt-api-key') for key in headers):
            raise ValueError('Authenticated redirect is forbidden')
        if urlsplit(following).netloc != urlsplit(url).netloc:
            headers = {k: v for k, v in headers.items() if k.lower() not in
                ('authorization', 'trakt-api-key', 'referer', 'origin')}
        # Writes and authenticated integrations never follow upstream redirects.
        if method not in ('GET', 'HEAD') or body: raise ValueError('Unsafe redirect')
        url = following
    raise ValueError('Redirect budget exceeded')


def approved(url, kind, data_dir=None):
    public_url(url)
    parsed = urlsplit(url)
    if kind == 'weather':
        return parsed.scheme == 'https' and parsed.port in (None, 443) and (
            parsed.hostname == 'geocoding-api.open-meteo.com' and parsed.path == '/v1/search' or
            parsed.hostname == 'api.open-meteo.com' and parsed.path == '/v1/forecast')
    if kind == 'epg': return url in EPG
    if kind == 'image':
        if parsed.scheme == 'https' and parsed.port in (None, 443):
            if parsed.hostname == 'image.tmdb.org' and parsed.path.startswith('/t/p/'): return True
            if parsed.hostname == 'raw.githubusercontent.com' and parsed.path.startswith('/tv-logo/tv-logos/main/countries/') and parsed.path.endswith(('.png', '.jpg', '.webp')): return True
    path = Path(data_dir or DATA) / 'channel_inventory.sqlite3'
    if path.is_file():
        with sqlite3.connect(f'file:{path}?mode=ro', uri=True, timeout=2) as conn:
            if kind == 'media':
                row = conn.execute('SELECT 1 FROM routes WHERE url=? AND success_at IS NOT NULL AND blocked=0 AND deleted=0 LIMIT 1', (canonical_route_url(url),)).fetchone()
            elif kind == 'image':
                row = conn.execute('SELECT 1 FROM routes WHERE logo_url=? AND success_at IS NOT NULL AND blocked=0 AND deleted=0 LIMIT 1', (url,)).fetchone()
            else: row = None
            if row: return True
    if kind == 'playlist':
        try:
            sources = json.loads((Path(__file__).parent / 'sources.json').read_text())['sources']
            return url in {source['url'] for source in sources}
        except (OSError, ValueError, KeyError): return False
    return False


def sign_child(url, root, headers=None, now=None, variables=None):
    public_url(url)
    payload = {'url': url, 'root': root, 'headers': headers or {},
        'expires': int(now or time.time()) + 12 * 3600}
    if variables is not None: payload['variables'] = variables
    encoded = base64.urlsafe_b64encode(json.dumps(payload, separators=(',', ':')).encode()).decode().rstrip('=')
    signature = hmac.new(_secret(DATA), ('egress-v1:' + encoded).encode(), hashlib.sha256).hexdigest()
    return ORIGIN + '/api/v1/egress/resource?' + urlencode({'kind': 'media', 'cap': encoded + '.' + signature})


def verify_child(token, now=None):
    try:
        if not isinstance(token, str) or len(token) > 16000: raise ValueError()
        body, signature = token.split('.')
        expected = hmac.new(_secret(DATA), ('egress-v1:' + body).encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature, expected): raise ValueError()
        payload = json.loads(base64.urlsafe_b64decode(body + '=' * (-len(body) % 4)))
        if payload['expires'] < int(now or time.time()): raise ValueError()
        public_url(payload['url'])
        if not approved(payload['root'], 'media'): raise ValueError()
        return payload
    except (ValueError, KeyError, TypeError): raise ValueError('Invalid media capability') from None


def rewrite_hls(text, base, root, headers=None):
    if not text.lstrip('\ufeff').startswith('#EXTM3U'): raise ValueError('Invalid HLS')
    if '{$' in text or '#EXT-X-CONTENT-STEERING' in text:
        raise ValueError('Unsupported HLS indirection')
    def child(value): return sign_child(urljoin(base, value), root, headers)
    lines = []
    for raw in text.lstrip('\ufeff').splitlines():
        line = raw.strip()
        if line and not line.startswith('#'):
            raw = child(line)
        elif line.startswith('#'):
            # Includes audio, subtitles, keys, maps, variants, LL-HLS hints.
            raw = re.sub(r'(?<![A-Z-])URI="([^"]*)"', lambda m: 'URI="' + child(m[1]) + '"', raw, flags=re.I)
            if re.search(r'(?<![A-Z-])URI=(?!")', raw, flags=re.I): raise ValueError('Unquoted HLS URI')
        lines.append(raw)
    return '\n'.join(lines) + '\n'


def rate(request, cost=1):
    key = hashlib.sha256((request.client.host if request.client else 'unknown').encode()).hexdigest()
    now = int(time.time()) // 60
    with _lock:
        old = _rates.get(key, (now, 0))
        count = (old[1] if old[0] == now else 0) + cost
        _rates[key] = (now, count)
        _rates.move_to_end(key)
        while len(_rates) > 10000: _rates.popitem(last=False)
    if count > 600: raise HTTPException(429, 'Gateway request limit', headers={'Retry-After': '60'})


def clean_headers(values, allowed=REQUEST_HEADERS):
    if not isinstance(values, dict) or len(values) > 32: raise ValueError('Invalid headers')
    result = {}
    for key, value in values.items():
        if not isinstance(key, str) or not isinstance(value, str) or len(value) > 4096 or '\r' in value or '\n' in value: raise ValueError('Invalid headers')
        if key.lower() in allowed: result[key.lower()] = value
    return result


def fetch_small(url, kind, headers=None, method='GET', body=None):
    response = upstream(url, headers, method, body)
    try:
        limit = MAX_EPG if kind == 'epg' else MAX_DATA
        data = response.read(limit + 1)
        if len(data) > limit: raise ValueError('Resource exceeds byte budget')
        result_headers = clean_headers(dict(response.headers), RESPONSE_HEADERS)
        result_headers['Cache-Control'] = 'no-store'
        return data, response.code, result_headers
    finally: response.close()


def cached_small(url, kind):
    global _cache_bytes
    key = (url, kind)
    with _lock:
        saved = _cache.get(key)
        if saved and saved[0] > time.time():
            _cache.move_to_end(key)
            return saved[1]
    result = fetch_small(url, kind)
    if result[1] == 200 and len(result[0]) <= 8 * 1024 * 1024:
        with _lock:
            old = _cache.pop(key, None)
            if old: _cache_bytes -= len(old[1][0])
            _cache[key] = (time.time() + (600 if kind == 'weather' else 86400), result)
            _cache_bytes += len(result[0])
            while _cache_bytes > 32 * 1024 * 1024 or len(_cache) > 128:
                _, removed = _cache.popitem(last=False)
                _cache_bytes -= len(removed[1][0])
    return result


def cached_epg(url):
    # Only the fixed reviewed feeds can populate this bounded disk cache.
    directory = Path(DATA) / 'egress-epg'
    directory.mkdir(exist_ok=True, mode=0o700)
    digest = hashlib.sha256(url.encode()).hexdigest()
    path, metadata = directory / digest, directory / (digest + '.json')
    with _epg_lock:
        if path.is_file() and metadata.is_file() and time.time() - path.stat().st_mtime < 14400:
            return path, json.loads(metadata.read_text())
        response = upstream(url)
        fd, temporary = tempfile.mkstemp(prefix='.epg-', dir=directory)
        try:
            total = 0
            with os.fdopen(fd, 'wb') as output:
                if response.code != 200: raise ValueError('EPG unavailable')
                while True:
                    chunk = response.read(64 * 1024)
                    if not chunk: break
                    total += len(chunk)
                    if total > MAX_EPG: raise ValueError('EPG exceeds byte budget')
                    output.write(chunk)
            if not total: raise ValueError('Empty EPG')
            headers = clean_headers(dict(response.headers), RESPONSE_HEADERS)
            headers['Cache-Control'] = 'private, max-age=900'
            os.chmod(temporary, 0o600)
            os.replace(temporary, path)
            meta_temp = metadata.with_suffix('.tmp')
            meta_temp.write_text(json.dumps(headers))
            os.chmod(meta_temp, 0o600)
            os.replace(meta_temp, metadata)
            return path, headers
        finally:
            response.close()
            if Path(temporary).exists(): Path(temporary).unlink()


def prepare_media(url, root, headers, method):
    response = upstream(url, headers, method)
    try:
        result_headers = clean_headers(dict(response.headers), RESPONSE_HEADERS)
        result_headers.update({'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no'})
        if response.code not in (200, 206) or method == 'HEAD':
            status = response.code
            response.close()
            return None, b'', status, result_headers
        prefix = response.read(4096)
        mime = result_headers.get('content-type', '').lower()
        encoding = result_headers.get('content-encoding', '').lower()
        is_manifest = 'mpegurl' in mime or 'xml' in mime or prefix.lstrip(b'\xef\xbb\xbf').startswith(b'#EXTM3U') or prefix.lstrip().startswith(b'<')
        if is_manifest:
            # Range probes must receive a complete, rewritten playlist.
            if response.code == 206:
                response.close()
                response = upstream(url, {k: v for k, v in headers.items() if k.lower() not in ('range', 'if-range')})
                prefix = response.read(4096)
            payload = prefix + response.read(MAX_PLAYLIST + 1 - len(prefix))
            if len(payload) > MAX_PLAYLIST: raise ValueError('Playlist exceeds limit')
            if encoding == 'gzip':
                decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
                payload = decoder.decompress(payload, MAX_PLAYLIST + 1)
                if len(payload) > MAX_PLAYLIST or not decoder.eof: raise ValueError('Compressed manifest exceeds limit')
            preserved = {k: v for k, v in headers.items() if k.lower() not in ('range', 'if-range')}
            if payload.lstrip(b'\xef\xbb\xbf').startswith(b'#EXTM3U'):
                output = rewrite_hls(payload.decode('utf-8-sig'), response.url, root, preserved).encode()
                content_type = 'application/vnd.apple.mpegurl'
            else:
                output = rewrite_mpd(payload, response.url, lambda child, variables:
                    sign_child(child, root, preserved, variables=variables))
                content_type = 'application/dash+xml'
            response.close()
            return None, output, 200, {'Content-Type': content_type,
                'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no'}
        if ('dash+xml' in mime or 'text/html' in mime or 'application/json' in mime or
                prefix.lstrip().startswith((b'<?xml', b'<MPD', b'<html', b'[playlist]'))):
            raise ValueError('Media format not supported by server relay')
        return response, prefix, response.code, result_headers
    except BaseException:
        response.close()
        raise


@router.api_route('/resource', methods=['GET', 'HEAD'])
async def resource(request: Request, kind: str, url: str = '', cap: str = '', headers: str = '{}'):
    rate(request)
    if kind not in ('media', 'image', 'epg', 'playlist', 'weather'): raise HTTPException(422, 'Unknown resource kind')
    try:
        supplied = clean_headers(json.loads(headers), {'user-agent', 'referer', 'origin'})
        if cap:
            if kind != 'media': raise ValueError()
            payload = await run_in_threadpool(verify_child, cap)
            url, root, supplied = payload['url'], payload['root'], payload['headers']
            if payload.get('variables'):
                url = expand_template(url, payload['variables'], request.query_params)
        else:
            root = url
            if not await run_in_threadpool(approved, url, kind): raise ValueError()
    except (ValueError, TypeError, json.JSONDecodeError): raise HTTPException(403, 'Resource is not approved for server relay') from None
    slots = SLOTS if kind == 'media' else SMALL_SLOTS
    if not slots.acquire(blocking=False): raise HTTPException(503, 'Gateway busy', headers={'Retry-After': '3'})
    handed_off = False
    try:
        if kind == 'epg':
            path, response_headers = await run_in_threadpool(cached_epg, url)
            return FileResponse(path, headers=response_headers)
        if kind != 'media':
            result = await run_in_threadpool(cached_small, url, kind)
            return Response(result[0] if request.method != 'HEAD' else b'', status_code=result[1], headers=result[2])
        for name in ('range', 'if-range'):
            if request.headers.get(name): supplied[name] = request.headers[name]
        stream, prefix, status, response_headers = await run_in_threadpool(prepare_media, url, root, supplied, request.method)
        if stream is None: return Response(prefix, status_code=status, headers=response_headers)
        released = False
        def close_stream():
            nonlocal released
            if released: return
            released = True
            stream.close()
            slots.release()
        def chunks():
            try:
                if prefix: yield prefix
                while True:
                    chunk = stream.read(64 * 1024)
                    if not chunk: break
                    yield chunk
            finally:
                close_stream()
        handed_off = True
        return StreamingResponse(chunks(), status_code=status, headers=response_headers,
            background=BackgroundTask(close_stream))
    except (ValueError, OSError, UnicodeError, urllib.error.URLError):
        raise HTTPException(502, 'Server could not load this resource') from None
    finally:
        if not handed_off: slots.release()


@router.post('/data')
async def data_relay(request: Request):
    rate(request, 3)
    raw = bytearray()
    async for chunk in request.stream():
        raw.extend(chunk)
        if len(raw) > 512 * 1024: raise HTTPException(413, 'Request exceeds limit')
    try:
        payload = json.loads(raw)
        if set(payload) != {'url', 'method', 'headers', 'body'}: raise ValueError()
        parsed = public_url(payload['url'])
        allowed = DATA_HOSTS.get(parsed.hostname, ())
        if parsed.scheme != 'https' or parsed.port not in (None, 443) or not any(parsed.path.startswith(path) for path in allowed): raise ValueError()
        if payload['method'] not in ('GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD'): raise ValueError()
        body = base64.b64decode(payload['body'], validate=True)
        if len(body) > 256 * 1024: raise ValueError()
        headers = clean_headers(payload['headers'])
    except (ValueError, TypeError, KeyError): raise HTTPException(403, 'Integration is not enabled on the server') from None
    if not SMALL_SLOTS.acquire(blocking=False): raise HTTPException(503, 'Gateway busy')
    try:
        result = await run_in_threadpool(fetch_small, payload['url'], 'data', headers,
            payload['method'], body or None)
        return Response(result[0], status_code=result[1], headers=result[2])
    except (OSError, ValueError, urllib.error.URLError): raise HTTPException(502, 'Integration unavailable') from None
    finally: SMALL_SLOTS.release()


@router.get('/logo-index')
async def logo_index(request: Request):
    rate(request, 3)
    path = Path(DATA) / 'egress-logo-index.json'
    if not path.is_file(): return {'logos': {}}
    return {'logos': json.loads(path.read_text())}


@router.get('/weather-location')
async def weather_location(request: Request):
    rate(request)
    from network_routes import _geo
    from source_candidates import _attribution
    address, _ = _attribution(request)
    directory = Path(os.environ.get('BOBTV_NETWORK_DB_DIR', DATA / 'network-db'))
    value = await run_in_threadpool(_geo, directory / 'city.mmdb', address)
    location = value.get('location', {})
    if not all(isinstance(location.get(key), (float, int)) for key in ('latitude', 'longitude')):
        raise HTTPException(404, 'Please select your weather city')
    return {'latitude': location['latitude'], 'longitude': location['longitude'],
        'city': value.get('city', {}).get('names', {}).get('en', ''),
        'postal': '', 'approximate': True}
