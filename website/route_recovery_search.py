"""Bounded public search and silent, isolated decode for one catalog channel.

Search text, playlists and web pages are data. They can never authorize a route,
change a target identity, supply executable instructions or bypass access checks.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import unicodedata
import urllib.error
import urllib.request
from urllib.parse import quote, urlencode, urljoin, urlsplit
from email.utils import parsedate_to_datetime
import xml.etree.ElementTree as ET

from catalog_inventory import validate_media_url
from process_channel_inventory import _HTTPHandler, _HTTPSHandler


class SearchDeferred(Exception):
    def __init__(self, code, retry_at):
        self.code, self.retry_at = code, int(retry_at)
        super().__init__(code)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def public_url(value, *, document=False):
    value = validate_media_url(value)
    parsed = urlsplit(value)
    if document and (parsed.scheme != 'https' or parsed.port):
        raise ValueError('public_https_document_required')
    return value


def read_public(url, *, limit=512 * 1024, deadline=None, allowed_hosts=None):
    """Connect only to checked numeric public DNS results, on every redirect."""
    deadline = time.monotonic() + 12 if deadline is None else deadline
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(),
                                        _HTTPHandler(), _HTTPSHandler())
    for _ in range(4):
        url = public_url(url)
        if allowed_hosts is not None and urlsplit(url).hostname not in allowed_hosts:
            raise ValueError('media_redirect_host_unreviewed')
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SearchDeferred('search_deadline', time.time() + 1800)
        try:
            request = urllib.request.Request(url, headers={'User-Agent': 'BobTV-Channel-Recovery/1',
                'Accept-Encoding': 'identity', 'Accept': '*/*', 'Range': f'bytes=0-{limit}'})
            with opener.open(request, timeout=min(6, remaining)) as response:
                if response.status not in (200, 206):
                    raise ValueError('unexpected_public_response')
                length = response.headers.get('Content-Length')
                if length and int(length) > limit:
                    raise ValueError('public_document_limit')
                if response.headers.get('Content-Encoding', 'identity').lower() not in ('', 'identity'):
                    raise ValueError('unrequested_compression')
                body = bytearray()
                while len(body) <= limit:
                    if time.monotonic() > deadline:
                        raise SearchDeferred('search_deadline', time.time() + 1800)
                    part = response.read(min(16384, limit + 1 - len(body)))
                    if not part:
                        break
                    body.extend(part)
                if len(body) > limit:
                    raise ValueError('public_document_limit')
                return bytes(body)
        except urllib.error.HTTPError as error:
            if error.code in (301, 302, 303, 307, 308):
                url = urljoin(url, error.headers.get('Location', ''))
                continue
            if error.code == 429 or (error.code == 403 and error.headers.get('X-RateLimit-Remaining') == '0'):
                stamp = int(time.time())
                header = error.headers.get('Retry-After', '3600')
                try:
                    after = stamp + int(header)
                except ValueError:
                    try:
                        after = int(parsedate_to_datetime(header).timestamp())
                    except (ValueError, TypeError, OverflowError):
                        after = stamp + 3600
                try:
                    reset = int(error.headers.get('X-RateLimit-Reset', '0'))
                except ValueError:
                    reset = 0
                retry = max(stamp + 300, reset, after)
                raise SearchDeferred('search_upstream_rate_limit', retry) from None
            raise ValueError('public_http_failure') from None
    raise ValueError('public_redirect_limit')


def folded(value):
    return ' '.join(unicodedata.normalize('NFKC', value).casefold().split())


def parse_candidates(text, source, channel, profile=None, *, country_context=None):
    """Exact full aliases/IDs only. No substring, quality, country or 5/5+ guesses."""
    aliases = {folded(channel['name'])}
    if profile:
        aliases.update(folded(s) for s in profile.get('aliases', []) if isinstance(s, str))
    ids = set((profile or {}).get('externalChannelIds', []))
    output, pending = [], None
    for line in text.splitlines()[:12000]:
        line = line.strip()
        if line.startswith('#EXTINF:'):
            attrs = dict(re.findall(r'([\w-]+)="([^"\r\n]{0,256})"', line))
            pending = (line.rsplit(',', 1)[-1].strip(), attrs)
        elif line and not line.startswith('#'):
            if pending:
                name, attrs = pending
                countries = re.split(r'[;,\s]+', attrs.get('tvg-country', country_context or ''))
                matched = (folded(name) in aliases or attrs.get('tvg-id') in ids)
                explicit_country = channel.get('countryCode') in countries
                if matched and explicit_country:
                    try:
                        url = public_url(line)
                        if urlsplit(url).query:
                            raise ValueError('ephemeral_or_signed_route_requires_review')
                        output.append({'name': name, 'url': url, 'source': source,
                            'externalChannelId': attrs.get('tvg-id'), 'countryCode': channel.get('countryCode')})
                    except ValueError:
                        pass
            pending = None
    if not output and profile and source in profile.get('approvedDocuments', []) and any(a in folded(text) for a in aliases):
        # A reviewed single-channel official page may expose a literal playlist.
        for value in re.findall(r'https?://[^\s<>"\x27\\]{1,2048}\.m3u8', text)[:5]:
            try:
                output.append({'name': channel['name'], 'url': public_url(value),
                    'source': source, 'countryCode': channel.get('countryCode')})
            except ValueError:
                pass
    return list({c['url']: c for c in output}.values())[:5]


def search_channel(channel, profile, directory, *, reader=read_public):
    deadline = time.monotonic() + 45
    cache = Path(directory) / 'route-recovery-cache'
    cache.mkdir(parents=True, exist_ok=True)
    # Only generated hash-named cache files are pruned, never catalog/history.
    files = sorted((p for p in cache.iterdir() if re.fullmatch(r'[a-f0-9]{64}', p.name)
                    and p.is_file() and not p.is_symlink()), key=lambda p: p.stat().st_mtime, reverse=True)
    total = 0
    for path in files:
        total += path.stat().st_size
        if total > 64 * 1024 * 1024 or time.time() - path.stat().st_mtime > 7 * 86400:
            path.unlink(missing_ok=True)
    sources, candidates = [], []

    def document(url, *, age=3600, limit=512 * 1024):
        public_url(url, document=True)
        key = hashlib.sha256(url.encode()).hexdigest()
        path = cache / key
        if path.is_file() and 0 <= time.time() - path.stat().st_mtime < age and path.stat().st_size <= limit:
            body = path.read_bytes()
            sources.append({'url': url, 'state': 'cached', 'checkedAt': int(time.time()),
                            'fetchedAt': int(path.stat().st_mtime), 'sha256': hashlib.sha256(body).hexdigest()})
            return body
        try:
            body = reader(url, limit=limit, deadline=deadline)
            if len(body) > limit:
                raise ValueError('public_document_limit')
        except SearchDeferred as error:
            sources.append({'url': url, 'state': 'deferred', 'checkedAt': int(time.time()),
                            'nextRetryAt': error.retry_at, 'errorCode': error.code})
            error.findings = {'sources': sources, 'queries': queries, 'candidates': candidates}
            raise
        except (OSError, ValueError):
            sources.append({'url': url, 'state': 'unavailable', 'checkedAt': int(time.time())})
            return None
        from publish_channel_catalog import _atomic_write
        _atomic_write(path, body)
        sources.append({'url': url, 'state': 'checked', 'checkedAt': int(time.time()),
                        'fetchedAt': int(time.time()), 'sha256': hashlib.sha256(body).hexdigest()})
        return body

    country = channel.get('countryCode') or ''
    queries = [f'"{channel["name"]}" {country} official live stream',
               f'"{channel["name"]}" {country} IPTV github m3u']
    # A public structured search request, no login, cookies or anti-bot bypass.
    # Links remain research leads until the separate identity/rights gate passes.
    for query in queries:
        raw = document('https://www.bing.com/search?' + urlencode({'format': 'rss', 'q': query}), limit=65536)
        if raw:
            try:
                tree = ET.fromstring(raw)
                for item in tree.findall('./channel/item')[:5]:
                    link = item.findtext('link') or ''
                    try:
                        public_url(link, document=True)
                        sources.append({'url': link, 'state': 'search_lead_only'})
                    except ValueError:
                        pass
            except ET.ParseError:
                pass
    repos = ['iptv-org/iptv', *(profile or {}).get('repositories', [])[:2]]
    raw = document('https://api.github.com/search/repositories?' + urlencode({
        'q': channel['name'] + ' IPTV ' + country, 'per_page': 2}))
    if raw:
        try:
            repos.extend(item['full_name'] for item in json.loads(raw).get('items', [])[:2])
        except (ValueError, KeyError, TypeError):
            pass
    checked_documents = set()
    for repo in list(dict.fromkeys(repos))[:3]:
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo) or time.monotonic() >= deadline:
            continue
        metadata = document('https://api.github.com/repos/' + repo, age=21600)
        try:
            branch = json.loads(metadata or b'{}')['default_branch']
            if not isinstance(branch, str) or len(branch) > 100:
                continue
        except (KeyError, ValueError, TypeError):
            continue
        raw = document('https://api.github.com/repos/' + repo + '/git/trees/' + quote(branch, safe='') + '?recursive=1', limit=1024 * 1024)
        try:
            nodes = json.loads(raw or b'{}').get('tree', [])
            paths = [n['path'] for n in nodes[:4000] if n.get('type') == 'blob'
                     and n.get('size', 0) <= 256 * 1024 and n.get('path', '').lower().endswith(('.m3u', '.m3u8', '.txt'))]
        except (ValueError, TypeError, KeyError):
            continue
        exact_country = [p for p in paths if country and Path(p).stem.casefold() == country.casefold()]
        named = [p for p in paths if folded(channel['name']).replace(' ', '') in folded(Path(p).stem).replace(' ', '')]
        # Actual tree paths only. No guessed URL templates or whole-repo crawl.
        for path in list(dict.fromkeys(exact_country + named))[:2]:
            if len(checked_documents) >= 4 or time.monotonic() >= deadline:
                break
            url = 'https://raw.githubusercontent.com/' + repo + '/' + quote(branch, safe='') + '/' + quote(path, safe='/')
            if url in checked_documents:
                continue
            checked_documents.add(url)
            body = document(url, limit=256 * 1024)
            if body:
                candidates.extend(parse_candidates(body.decode('utf-8-sig', errors='replace'), url,
                    channel, profile, country_context=country if path in exact_country else None))
    for url in (profile or {}).get('approvedDocuments', [])[:3]:
        if time.monotonic() >= deadline:
            break
        if url in checked_documents:
            continue
        checked_documents.add(url)
        body = document(url, limit=256 * 1024)
        if body:
            candidates.extend(parse_candidates(body.decode('utf-8-sig', errors='replace'), url,
                                               channel, profile, country_context=country))
    return {'queries': queries, 'sources': sources,
            'candidates': list({c['url']: c for c in candidates}.values())[:5]}


def decode_candidate(url, profile, *, reader=read_public, execute=subprocess.run):
    """Bound media bytes first; FFmpeg sees only local bytes and a null sink."""
    decoder = os.environ.get('BOBTV_ROUTE_DECODER') or shutil.which('ffmpeg')
    if not decoder:
        raise SearchDeferred('media_decoder_unavailable', time.time() + 21600)
    hosts = set(profile.get('mediaHosts', []))
    deadline = time.monotonic() + 12
    prefix = b''
    for _ in range(4):
        body = reader(url, limit=2 * 1024 * 1024, deadline=deadline, allowed_hosts=hosts)
        if body.lstrip().startswith(b'#EXTM3U'):
            text = body.decode('utf-8-sig')
            if any(not line.startswith('#EXT-X-KEY:METHOD=NONE') for line in text.splitlines() if line.startswith('#EXT-X-KEY:')):
                return False  # No encrypted, authenticated or DRM extraction.
            init = re.search(r'#EXT-X-MAP:.*?URI="([^"\r\n]+)"', text)
            if init:
                prefix = reader(urljoin(url, init[1]), limit=256 * 1024,
                                deadline=deadline, allowed_hosts=hosts)
            targets = [line.strip() for line in text.splitlines() if line.strip() and not line.startswith('#')]
            if not targets:
                return False
            url = public_url(urljoin(url, targets[-1] if '#EXTINF:' in text else targets[0]))
            continue
        if not body or body.lstrip().startswith((b'<', b'{', b'[')):
            return False
        with tempfile.TemporaryDirectory(prefix='bobtv-route-decode-') as temporary:
            media = Path(temporary) / 'sample.media'
            media.write_bytes(prefix + body)
            stream = '0:a:0' if profile.get('broadcastType') == 'radio' else '0:v:0'
            try:
                result = execute([decoder, '-nostdin', '-v', 'error', '-threads', '1',
                    '-filter_threads', '1', '-max_alloc', '33554432', '-protocol_whitelist', 'file,pipe',
                    '-analyzeduration', '2000000', '-probesize', '2097152', '-i', str(media),
                    '-map', stream, '-t', '1', '-progress', 'pipe:1', '-f', 'null', '-'],
                    capture_output=True, timeout=8, check=False)
                progress = result.stdout.decode('ascii', errors='ignore')
                field = 'out_time_us' if profile.get('broadcastType') == 'radio' else 'frame'
                counts = re.findall(r'^' + field + r'=(\d+)\s*$', progress, re.M)
                return result.returncode == 0 and any(int(value) > 0 for value in counts)
            except (OSError, subprocess.TimeoutExpired):
                return False
    return False
