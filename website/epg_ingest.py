"""Bounded XMLTV validation and resumable server-side source health probes.

This first stage does not publish EPG or apply channel mappings. Source code
licenses never substitute for programme-data redistribution permission.
"""
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import random
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urljoin, urlsplit
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
import xml.etree.ElementTree as ET
import zlib

from catalog_inventory import DATA
from process_channel_inventory import _HTTPHandler, _HTTPSHandler
from source_registry import validate_public_url

MAX_COMPRESSED = 8 * 1024 * 1024
MAX_DECODED = 32 * 1024 * 1024
MAX_PROGRAMMES = 200_000
MAX_CHANNELS = 10_000
REGISTRY = Path(__file__).with_name('epg_sources.json')


class EpgError(ValueError):
    """A fixed diagnostic code, never an upstream response body or credential."""

    def __init__(self, code, retry_after=0):
        super().__init__(code)
        self.retry_after = retry_after


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def reviewed_redirect(source, url):
    """Only the reviewed origin, country filename and 32-hex version directory."""
    if url in {source['url'], *source.get('redirectUrls', [])}:
        return True
    if source.get('redirectPolicy') != {'kind': 'same_origin_versioned_xmltv_v1'}:
        return False
    original, target = urlsplit(source['url']), urlsplit(url)
    if (original.scheme != 'https' or target.scheme != 'https'
            or original.netloc != target.netloc or target.query or target.fragment
            or target.username or target.password or target.port):
        return False
    if not re.fullmatch(r'/files/epg-[a-z]{2}\.xml\.gz', original.path):
        return False
    return bool(re.fullmatch(r'/files/[0-9a-f]{32}/' + re.escape(original.path.rsplit('/', 1)[1]), target.path))


def registry(path=REGISTRY):
    value = json.loads(Path(path).read_text())
    if not isinstance(value, dict) or set(value) != {'schemaVersion', 'sources'} or value['schemaVersion'] != 1:
        raise EpgError('invalid_registry')
    sources = value['sources']
    if not isinstance(sources, list) or len(sources) > 100:
        raise EpgError('invalid_registry')
    seen = set()
    for source in sources:
        if not isinstance(source, dict) or not re.fullmatch(r'[a-z0-9-]{1,64}', source.get('id', '')) or source['id'] in seen:
            raise EpgError('invalid_source_id')
        seen.add(source['id'])
        validate_public_url(source['url'])
        for url in source.get('redirectUrls', []):
            validate_public_url(url)
        if 'redirectPolicy' in source:
            if (source['redirectPolicy'] != {'kind': 'same_origin_versioned_xmltv_v1'}
                    or not re.fullmatch(r'/files/epg-[a-z]{2}\.xml\.gz', urlsplit(source['url']).path)):
                raise EpgError('invalid_redirect_policy')
        if 'supersedes' in source:
            previous = source['supersedes']
            if (not isinstance(previous, dict) or set(previous) != {'sourceId', 'reason'}
                    or not re.fullmatch(r'[a-z0-9-]{1,64}', previous.get('sourceId', ''))
                    or previous['sourceId'] == source['id']
                    or not isinstance(previous.get('reason'), str) or not 1 <= len(previous['reason']) <= 512):
                raise EpgError('invalid_source_replacement')
        if type(source.get('refreshSeconds')) is not int or not 900 <= source['refreshSeconds'] <= 7 * 86400:
            raise EpgError('invalid_refresh_interval')
        if 'minimumRetrySeconds' in source and (type(source['minimumRetrySeconds']) is not int
                or not 900 <= source['minimumRetrySeconds'] <= min(86400, source['refreshSeconds'])):
            raise EpgError('invalid_minimum_retry_interval')
        if source.get('format', 'xmltv') not in ('xmltv', 'tvmaze-json', 'cctv-json', 'taipei-monthly-csv'):
            raise EpgError('unsupported_source_format')
        if source.get('format') == 'taipei-monthly-csv':
            if (source['id'] != 'taipei-radio-opendata-v1'
                    or source['url'] != 'https://data.gov.tw/dataset/121175'
                    or source.get('countryCode') != 'TW'
                    or source.get('calendarTimezone') != 'Asia/Taipei'
                    or source.get('redirectUrls') or source.get('redirectPolicy')
                    or source['refreshSeconds'] < 3600):
                raise EpgError('invalid_taipei_source')
        if source.get('format') == 'tvmaze-json':
            if (source['url'] != 'https://api.tvmaze.com/schedule'
                    or not re.fullmatch(r'[A-Z]{2}', source.get('countryCode', ''))
                    or source.get('redirectUrls') or source.get('redirectPolicy')
                    or source['refreshSeconds'] < 3600):
                raise EpgError('invalid_tvmaze_source')
            try:
                ZoneInfo(source['calendarTimezone'])
            except (KeyError, TypeError, ValueError, ZoneInfoNotFoundError):
                raise EpgError('invalid_schedule_calendar_timezone') from None
        if source.get('format') == 'cctv-json':
            if (source['id'] != 'cctv2-official-diagnostic-v1'
                    or source['url'] != 'https://api.cntv.cn/epg/getEpgInfoByChannelNew'
                    or source.get('channelId') != 'cctv2' or source.get('countryCode') != 'CN'
                    or source.get('calendarTimezone') != 'Asia/Shanghai'
                    or source.get('redirectUrls') or source.get('redirectPolicy')
                    or source['refreshSeconds'] < 3600):
                raise EpgError('invalid_cctv_source')
        if not isinstance(source.get('dataLicense'), dict) or type(source.get('publicationAllowed')) is not bool:
            raise EpgError('missing_data_rights_review')
        # A health probe cannot silently become a publishing worker.
        if source['publicationAllowed']:
            raise EpgError('publishing_not_implemented')
    if any(source.get('supersedes', {}).get('sourceId') in seen for source in sources):
        raise EpgError('replacement_source_still_active')
    return sources


def source_day(source, now):
    return datetime.fromtimestamp(now, ZoneInfo(source['calendarTimezone'])).date().isoformat()


def fetch_source(source, now):
    if source.get('format') == 'taipei-monthly-csv':
        from epg_taipei import fetch_schedule
        return fetch_schedule(now)
    if source.get('format') == 'cctv-json':
        from epg_cctv import fetch_schedule
        return fetch_schedule(source['channelId'], source_day(source, now).replace('-', ''))
    if source.get('format') == 'tvmaze-json':
        from epg_tvmaze import fetch_schedule
        return fetch_schedule(source['countryCode'], source_day(source, now))
    return fetch(source)


def parse_source(source, payload, now):
    if source.get('format') == 'taipei-monthly-csv':
        from epg_taipei import parse_schedule
        return parse_schedule(payload, now)
    if source.get('format') == 'cctv-json':
        from epg_cctv import parse_schedule
        value = parse_schedule(payload, source['channelId'], source_day(source, now).replace('-', ''), now)
        identity = value['identity']
        return {'channels': {identity['id']: [identity['name']]},
            'identityContexts': {identity['id']: {**identity,
                'sourceTimestampEncoding': 'unix_seconds_utc',
                'sourceCalendarTimezoneVerified': False}},
            'programmes': value['programmes'], 'quality': {**value['quality'],
                'usableChannels': 1,
                'coverageStartUtc': min((p['startUtc'] for p in value['programmes']), default=None),
                'coverageEndUtc': max((p['endUtc'] for p in value['programmes']), default=None)}}
    if source.get('format') != 'tvmaze-json':
        return parse_xmltv(payload, now)
    from epg_tvmaze import parse_schedule
    value = parse_schedule(payload, source['countryCode'], source_day(source, now), now)
    q = value['quality']
    return {'channels': {i['id']: [i['name']] for i in value['identities']},
        'identityContexts': {i['id']: {'countryCode': i['countryCode'], 'sourceTimezone': i['sourceTimezone'],
            'originalNetworkId': i['originalNetworkId'], 'contextVerifiedForCatalog': False}
            for i in value['identities']},
        'programmes': value['programmes'], 'quality': {**q,
            'acceptedProgrammes': q['acceptedEpisodes'], 'usableChannels': q['sourceNetworks'],
            'currentChannels': q['currentNetworks'], 'futureChannels': q['futureNetworks'],
            'currentAndFutureChannels': q['currentAndFutureNetworks'],
            'coverageStartUtc': min((p['startUtc'] for p in value['programmes']), default=None),
            'coverageEndUtc': max((p['endUtc'] for p in value['programmes']), default=None)}}


def fetch(source, opener=None, clock=time.monotonic):
    """Pinned public DNS, reviewed redirects, TLS, total/size bounds."""
    opener = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}),
        NoRedirect(), _HTTPHandler(), _HTTPSHandler())
    url, started = source['url'], clock()
    for _ in range(4):
        if not reviewed_redirect(source, url):
            raise EpgError('unreviewed_redirect')
        validate_public_url(url)
        try:
            response = opener.open(urllib.request.Request(url, headers={
                'User-Agent': 'BobTV-EPG-Validator/1.0', 'Accept-Encoding': 'identity',
            }), timeout=8)
        except urllib.error.HTTPError as exc:
            response = exc
        with response:
            if response.code in (301, 302, 303, 307, 308):
                url = urljoin(url, response.headers.get('Location', ''))
                continue
            if response.code != 200:
                retry = response.headers.get('Retry-After', '')
                try:
                    retry = int(retry) if retry.isdecimal() else max(0, int(parsedate_to_datetime(retry).timestamp() - time.time()))
                except (ValueError, TypeError, OverflowError):
                    retry = 0
                raise EpgError('http_' + str(response.code), max(0, retry))
            chunks, size = [], 0
            while True:
                if clock() - started > 32:
                    raise EpgError('fetch_deadline')
                chunk = response.read(64 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_COMPRESSED:
                    raise EpgError('compressed_size_limit')
                chunks.append(chunk)
            return b''.join(chunks), {
                'sourceUrl': source['url'], 'finalUrl': url,
                'lastModified': response.headers.get('Last-Modified'),
                'cacheControl': response.headers.get('Cache-Control'),
            }
    raise EpgError('redirect_limit')


def _decode_payload(payload):
    if not payload or len(payload) > MAX_COMPRESSED:
        raise EpgError('compressed_size_limit')
    if payload.startswith(b'\x1f\x8b'):
        try:
            decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
            raw = decoder.decompress(payload, MAX_DECODED + 1)
            if len(raw) > MAX_DECODED or not decoder.eof or decoder.unused_data:
                raise EpgError('gzip_size_or_integrity')
        except zlib.error:
            raise EpgError('invalid_gzip') from None
    else:
        raw = payload
    if len(raw) > MAX_DECODED:
        raise EpgError('decoded_size_limit')
    # UTF-8 only in this adapter. Reject NUL to prevent UTF-16 DTD bypasses.
    if b'\x00' in raw or b'<!ENTITY' in raw.upper():
        raise EpgError('unsafe_xml_declaration')
    try:
        text = raw.decode('utf-8-sig')
    except UnicodeError:
        raise EpgError('unsupported_encoding') from None
    declaration = re.match(r'\ufeff?\s*<\?xml\b[^?]*\bencoding\s*=\s*[\'"]([^\'"]+)[\'"]', text, re.I)
    if declaration and declaration[1].lower() not in ('utf-8', 'utf8'):
        raise EpgError('unsupported_encoding')
    return raw


def decode(payload):
    raw = _decode_payload(payload)
    if b'<!DOCTYPE' in raw.upper():
        raise EpgError('unsafe_xml_declaration')
    return raw


def _strip_standard_xmltv_doctype(raw):
    """Discard one fixed prolog reference; no DTD is ever loaded or resolved."""
    upper = raw.upper()
    if b'<!DOCTYPE' not in upper:
        return raw, False
    index = raw.find(b'<!DOCTYPE')
    if upper.count(b'<!DOCTYPE') != 1 or not 0 <= index <= 4096:
        raise EpgError('unsafe_xml_declaration')
    prefix = raw[:index].decode('utf-8-sig').strip()
    if prefix and not re.fullmatch(r'<\?xml\s+[^<>?]{1,512}\?>', prefix):
        raise EpgError('unsafe_xml_declaration')
    declaration = re.match(br'''<!DOCTYPE\s+tv\s+SYSTEM\s+(['"])xmltv\.dtd\1\s*>''', raw[index:index + 256])
    if not declaration:
        raise EpgError('unsafe_xml_declaration')
    end = index + declaration.end()
    if not re.match(br'<tv(?=[\s/>])', raw[end:].lstrip()):
        raise EpgError('unsafe_xml_declaration')
    return raw[:index] + raw[end:], True


def timestamp(value):
    if not re.fullmatch(r'\d{12}(?:\d{2})? [+-]\d{4}', value):
        raise EpgError('missing_explicit_timezone')
    try:
        fmt = '%Y%m%d%H%M%S %z' if len(value.split()[0]) == 14 else '%Y%m%d%H%M %z'
        return int(datetime.strptime(value, fmt).timestamp())
    except ValueError:
        raise EpgError('invalid_timestamp') from None


def parse_xmltv(payload, now=None):
    now = int(time.time() if now is None else now)
    raw, doctype_removed = _strip_standard_xmltv_doctype(_decode_payload(payload))
    channels, ambiguous, candidates = {}, set(), defaultdict(list)
    rejected, count = Counter(), 0
    try:
        events = ET.iterparse(io.BytesIO(raw), events=('start', 'end'))
        event, root = next(events)
        if root.tag != 'tv':
            raise EpgError('not_xmltv')
        for event, item in events:
            if event != 'end':
                continue
            if item.tag == 'channel':
                identity = item.get('id', '').strip()
                names = sorted({(n.text or '').strip() for n in item.findall('display-name')} - {''})
                if not identity or len(identity) > 256 or not names or len(names) > 16 or any(len(n) > 256 for n in names):
                    rejected['invalid_channel'] += 1
                elif identity in channels and channels[identity] != names:
                    ambiguous.add(identity)
                else:
                    channels[identity] = names
                if len(channels) > MAX_CHANNELS:
                    raise EpgError('channel_limit')
                item.clear()
            elif item.tag == 'programme':
                count += 1
                if count > MAX_PROGRAMMES:
                    raise EpgError('programme_limit')
                identity, title = item.get('channel', ''), (item.findtext('title') or '').strip()
                try:
                    start = timestamp(item.get('start', ''))
                    stop = timestamp(item.get('stop')) if item.get('stop') else None
                    if not identity or not title or len(title) > 512 or stop is not None and stop <= start:
                        raise EpgError('invalid_programme')
                    candidates[identity].append({
                        'originalChannelId': identity, 'title': title,
                        'startUtc': start, 'endUtc': stop,
                        'sourceStart': item.get('start'), 'sourceStop': item.get('stop'),
                        'sourceTimezone': item.get('start').split()[-1],
                        'endBasis': 'explicit_stop' if stop else 'next_start',
                    })
                except EpgError as exc:
                    rejected[str(exc)] += 1
                item.clear()
    except (ET.ParseError, StopIteration):
        raise EpgError('invalid_xml') from None
    for identity in ambiguous:
        channels.pop(identity, None)
    programmes = []
    for identity, rows in candidates.items():
        if identity not in channels:
            rejected['unknown_or_ambiguous_channel'] += len(rows)
            continue
        # Conflicting titles/stops at the same start have no reliable ordering.
        starts = defaultdict(dict)
        for row in rows:
            starts[row['startUtc']][(row['title'], row['endUtc'])] = row
        ordered_starts = sorted(starts)
        for index, start in enumerate(ordered_starts):
            variants = starts[start]
            if len(variants) != 1:
                rejected['conflicting_start'] += len(variants)
                continue
            row = dict(next(iter(variants.values())))
            following = ordered_starts[index + 1] if index + 1 < len(ordered_starts) else None
            if row['endUtc'] is None:
                if following is None or len(starts[following]) != 1:
                    rejected['missing_reliable_stop'] += 1
                    continue
                row['endUtc'] = following
                row['derivedFromStartUtc'] = following
            if following is not None and row['endUtc'] > following or row['endUtc'] - start > 24 * 3600:
                rejected['overlapping_or_long_programme'] += 1
                continue
            if row['endUtc'] < now - 2 * 86400 or start > now + 14 * 86400:
                continue
            programmes.append(row)
    current = {p['originalChannelId'] for p in programmes if p['startUtc'] <= now < p['endUtc']}
    future = {p['originalChannelId'] for p in programmes if p['startUtc'] > now}
    return {'channels': channels, 'programmes': programmes, 'quality': {
        **({'standardXmltvDoctypeRemoved': True, 'externalDtdResolved': False} if doctype_removed else {}),
        'declaredChannels': len(channels) + len(ambiguous),
        'usableChannels': len(channels), 'ambiguousChannelIds': sorted(ambiguous),
        'inputProgrammes': count, 'acceptedProgrammes': len(programmes),
        'currentChannels': len(current), 'futureChannels': len(future),
        'currentAndFutureChannels': len(current & future),
        'coverageStartUtc': min((p['startUtc'] for p in programmes), default=None),
        'coverageEndUtc': max((p['endUtc'] for p in programmes), default=None),
        'rejected': dict(rejected),
    }}


def database(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    conn = sqlite3.connect(directory / 'epg.sqlite3', timeout=5)
    conn.row_factory = sqlite3.Row
    conn.executescript('''
      CREATE TABLE IF NOT EXISTS source_health (
        id TEXT PRIMARY KEY, url TEXT NOT NULL, configuration TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending', failures INTEGER NOT NULL DEFAULT 0,
        last_attempt INTEGER, last_success INTEGER, last_failure INTEGER,
        next_retry INTEGER NOT NULL DEFAULT 0, last_error TEXT, content_sha256 TEXT,
        last_good_quality TEXT, last_attempt_quality TEXT, response_metadata TEXT);
      CREATE TABLE IF NOT EXISTS probe_audit (
        id INTEGER PRIMARY KEY, source_id TEXT NOT NULL, checked_at INTEGER NOT NULL,
        state TEXT NOT NULL, error_code TEXT, sha256 TEXT, quality TEXT);
      CREATE TABLE IF NOT EXISTS source_identities (
        source_id TEXT NOT NULL, original_id TEXT NOT NULL, names_json TEXT NOT NULL,
        observed_at INTEGER NOT NULL, fetched_at INTEGER NOT NULL,
        content_sha256 TEXT NOT NULL, origin TEXT NOT NULL,
        coverage_start INTEGER, coverage_end INTEGER,
        PRIMARY KEY(source_id,original_id));
      CREATE TABLE IF NOT EXISTS source_replacements (
        old_source_id TEXT PRIMARY KEY, new_source_id TEXT NOT NULL,
        reviewed_at INTEGER NOT NULL, reason TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS source_identity_context (
        source_id TEXT NOT NULL, original_id TEXT NOT NULL,
        context_json TEXT NOT NULL, observed_at INTEGER NOT NULL,
        PRIMARY KEY(source_id,original_id));
    ''')
    return conn


def save_identities(conn, source_id, parsed, digest, observed_at, fetched_at, origin):
    """Internal metadata only, never a public schedule or approved mapping."""
    bounds = {}
    for row in parsed['programmes']:
        key = row['originalChannelId']
        start, end = bounds.get(key, (row['startUtc'], row['endUtc']))
        bounds[key] = min(start, row['startUtc']), max(end, row['endUtc'])
    conn.execute('DELETE FROM source_identities WHERE source_id=?', (source_id,))
    conn.execute('DELETE FROM source_identity_context WHERE source_id=?', (source_id,))
    conn.executemany('INSERT INTO source_identities VALUES(?,?,?,?,?,?,?,?,?)', [
        (source_id, identity, json.dumps(names, ensure_ascii=False), observed_at,
         fetched_at, digest, origin, *bounds.get(identity, (None, None)))
        for identity, names in parsed['channels'].items()])
    conn.executemany('INSERT INTO source_identity_context VALUES(?,?,?,?)', [
        (source_id, identity, json.dumps(context, sort_keys=True), observed_at)
        for identity, context in parsed.get('identityContexts', {}).items()])


def seed_cached_identities(directory, sources, cache_directory, now=None):
    """One-time local cache bootstrap. No upstream requests, no fake fetch time."""
    now = int(time.time() if now is None else now)
    conn = database(directory)
    seeded = []
    try:
        for source in sources:
            if source.get('format') in ('tvmaze-json', 'cctv-json', 'taipei-monthly-csv'):
                continue  # Legacy egress cache contains XMLTV, never JSON schedules.
            if conn.execute('SELECT 1 FROM source_identities WHERE source_id=? LIMIT 1', (source['id'],)).fetchone():
                continue
            path = Path(cache_directory) / hashlib.sha256(source['url'].encode()).hexdigest()
            if not path.is_file() or now - path.stat().st_mtime > 86400 or path.stat().st_size > MAX_COMPRESSED:
                continue
            payload = path.read_bytes()
            try:
                parsed = parse_xmltv(payload, now)
                if not parsed['quality']['currentAndFutureChannels']:
                    continue
            except EpgError:
                continue
            digest = hashlib.sha256(payload).hexdigest()
            with conn:
                save_identities(conn, source['id'], parsed, digest, now,
                    int(path.stat().st_mtime), 'existing_egress_cache')
                conn.execute('INSERT INTO probe_audit(source_id,checked_at,state,sha256,quality) VALUES(?,?,?,?,?)',
                    (source['id'], now, 'identity_cache_seed', digest, json.dumps(parsed['quality'])))
            seeded.append(source['id'])
        return seeded
    finally:
        conn.close()


def probe_batch(directory, sources, now=None, fetcher=None, batch_size=1):
    """One serial fetch per run by default, checkpointed and idempotent when idle."""
    if type(batch_size) is not int or not 1 <= batch_size <= 5:
        raise EpgError('batch_size_limit')
    now = int(time.time() if now is None else now)
    conn = database(directory)
    try:
        with conn:
            for source in sources:
                encoded = json.dumps(source, sort_keys=True)
                previous = conn.execute('SELECT url,configuration FROM source_health WHERE id=?', (source['id'],)).fetchone()
                if previous and (previous['url'] != source['url'] or previous['configuration'] != encoded):
                    # Preserve prior evidence; operator must give a changed source a new ID.
                    raise EpgError('source_configuration_changed')
                conn.execute('INSERT OR IGNORE INTO source_health(id,url,configuration) VALUES(?,?,?)',
                    (source['id'], source['url'], encoded))
                replacement = source.get('supersedes')
                if replacement:
                    old_id = replacement['sourceId']
                    old = conn.execute('SELECT url FROM source_health WHERE id=?', (old_id,)).fetchone()
                    evidence = conn.execute('SELECT new_source_id,reason FROM source_replacements WHERE old_source_id=?', (old_id,)).fetchone()
                    if (not old or old['url'] != source['url'] or old_id in {s['id'] for s in sources}
                            or evidence and (evidence['new_source_id'] != source['id'] or evidence['reason'] != replacement['reason'])):
                        raise EpgError('invalid_source_replacement')
                    if not evidence:
                        conn.execute('INSERT INTO source_replacements VALUES(?,?,?,?)',
                            (old_id, source['id'], now, replacement['reason']))
                        conn.execute("UPDATE source_health SET state='superseded' WHERE id=?", (old_id,))
                        conn.execute('INSERT INTO probe_audit(source_id,checked_at,state,error_code) VALUES(?,?,?,?)',
                            (old_id, now, 'superseded', 'reviewed_configuration_replacement'))
        attempted = 0
        for source in sources:
            row = conn.execute('SELECT * FROM source_health WHERE id=?', (source['id'],)).fetchone()
            if row['state'] == 'manual_review':
                continue
            if row['last_error'] in ('http_401', 'http_403'):
                # Older workers only paused CCTV. Reconcile existing denied
                # sources without another access attempt or a fake fetch time.
                with conn:
                    conn.execute("UPDATE source_health SET state='manual_review' WHERE id=?",
                        (source['id'],))
                    conn.execute('INSERT INTO probe_audit(source_id,checked_at,state,error_code) VALUES(?,?,?,?)',
                        (source['id'], now, 'manual_review', row['last_error']))
                continue
            if row['next_retry'] > now or attempted >= batch_size:
                continue
            if source.get('format') == 'tvmaze-json' and conn.execute('''SELECT 1 FROM source_health
              WHERE url=? AND state!='superseded' AND last_error='http_429' AND next_retry>? LIMIT 1''',
                    (source['url'], now)).fetchone():
                # Same-provider rate limits also apply to country discovery.
                # Other providers keep their existing scheduling configuration.
                continue
            attempted += 1
            # Commit before network I/O: a killed worker cannot repeatedly fetch
            # the same failed source on every timer tick without any checkpoint.
            with conn:
                if row['state'] == 'probing':
                    conn.execute('UPDATE source_health SET last_failure=?,last_error=? WHERE id=?',
                        (row['last_attempt'], 'worker_interrupted', source['id']))
                    conn.execute('INSERT INTO probe_audit(source_id,checked_at,state,error_code) VALUES(?,?,?,?)',
                        (source['id'], now, 'failed', 'worker_interrupted'))
                resume_delay = max(120, min(6 * 3600, 60 * 2 ** min(row['failures'], 9)))
                resume_delay = max(resume_delay, source.get('minimumRetrySeconds', 0))
                conn.execute('UPDATE source_health SET state=?,last_attempt=?,failures=?,next_retry=? WHERE id=?',
                    ('probing', now, row['failures'] + 1, now + resume_delay, source['id']))
                conn.execute('INSERT INTO probe_audit(source_id,checked_at,state) VALUES(?,?,?)',
                    (source['id'], now, 'probing'))
            quality, digest, metadata, error, retry_after = None, None, None, None, 0
            try:
                payload, metadata = fetcher(source) if fetcher is not None else fetch_source(source, now)
                digest = hashlib.sha256(payload).hexdigest()
                parsed = parse_source(source, payload, now)
                quality = parsed['quality']
                if not quality['acceptedProgrammes']:
                    raise EpgError('empty_or_expired_data')
                state = 'healthy'
                if (source.get('format') == 'taipei-monthly-csv'
                        and quality.get('currentConflictRecords') and quality['futureChannels']):
                    # The exact licensed CSV can have an ambiguous current hour
                    # while retaining valid, dated future records. Keep those
                    # records as partial data; current coverage stays zero and
                    # the per-channel conflict review remains active.
                    state = 'partial'
                    quality['coverageStatus'] = 'current_slot_conflict_requires_review'
                elif (source.get('format') in ('tvmaze-json', 'cctv-json') and not quality['currentAndFutureChannels']
                        and (quality['currentChannels'] or quality['futureChannels'])):
                    state = 'partial'
                    quality['coverageStatus'] = 'sparse_current_or_future_only'
                elif not quality['currentAndFutureChannels']:
                    raise EpgError('insufficient_current_future_coverage')
            except EpgError as exc:
                state, error = 'failed', str(exc)
                retry_after = exc.retry_after
                if error in ('http_401', 'http_403'):
                    state = 'manual_review'
            except (OSError, urllib.error.URLError, TimeoutError):
                state, error = 'failed', 'network_failure'
            except ValueError:
                state, error = 'failed', 'invalid_or_unsafe_source'
            failures = row['failures'] + 1 if error else 0
            delay = max(retry_after, min(6 * 3600, 60 * 2 ** min(failures - 1, 9))) + random.randint(0, 5) if error else source['refreshSeconds']
            if error:
                delay = max(delay, source.get('minimumRetrySeconds', 0))
            if (source.get('format') == 'cctv-json'
                    or source.get('format') == 'tvmaze-json' and metadata is not None):
                # Provider caches output for an hour. Empty/invalid dated data
                # must not be re-downloaded each minute while that cache is fresh.
                delay = max(delay, source['refreshSeconds'])
            if not error and source.get('format') == 'taipei-monthly-csv':
                from epg_taipei import success_refresh_delay
                delay = success_refresh_delay(now, delay)
            with conn:
                if not error:
                    save_identities(conn, source['id'], parsed, digest, now, now, 'server_fetch')
                conn.execute('''UPDATE source_health SET state=?, failures=?, last_attempt=?,
                  last_success=CASE WHEN ? IS NULL THEN ? ELSE last_success END,
                  last_failure=CASE WHEN ? IS NOT NULL THEN ? ELSE last_failure END,
                  next_retry=?,last_error=?,content_sha256=CASE WHEN ? IS NULL THEN ? ELSE content_sha256 END,
                  last_good_quality=CASE WHEN ? IS NULL THEN ? ELSE last_good_quality END,
                  last_attempt_quality=?,response_metadata=? WHERE id=?''',
                  (state, failures, now, error, now, error, now, now + delay, error,
                   error, digest, error, json.dumps(quality), json.dumps(quality), json.dumps(metadata), source['id']))
                conn.execute('INSERT INTO probe_audit(source_id,checked_at,state,error_code,sha256,quality) VALUES(?,?,?,?,?,?)',
                    (source['id'], now, state, error, digest, json.dumps(quality)))
            if not error:
                # Reuse this validated fetch for licensed, approved identities.
                # Unapproved sources remain metadata-only diagnostics.
                from epg_store import cache_validated_payload
                try:
                    if source.get('format') == 'taipei-monthly-csv':
                        from epg_taipei import refresh_existing_credit
                        refresh_existing_credit(conn, quality['resourceTitle'])
                    cache_validated_payload(conn, directory, source['id'], payload, now)
                except (EpgError, OSError, sqlite3.Error):
                    with conn:
                        conn.execute('INSERT INTO probe_audit(source_id,checked_at,state,error_code) VALUES(?,?,?,?)',
                            (source['id'], now, 'cache_failed', 'programme_cache_handoff_failed'))
        return {'schemaVersion': 1, 'stage': 'source_validation', 'checkedAtUtc': now,
            'attemptedSources': attempted, 'published': False,
            'sources': [dict(row) for row in conn.execute('SELECT * FROM source_health ORDER BY id')]}
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--registry', type=Path, default=REGISTRY)
    parser.add_argument('--data-dir', type=Path, default=Path(DATA) / 'epg')
    args = parser.parse_args()
    args.data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (args.data_dir / 'worker.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(json.dumps({'state': 'already_running'}))
            return
        result = probe_batch(args.data_dir, registry(args.registry))
        print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    # Lazy adapters import this module's shared errors and bounded I/O helpers.
    # Preserve the same EpgError identity when the worker runs as a script.
    sys.modules['epg_ingest'] = sys.modules[__name__]
    main()
