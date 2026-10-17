"""Network-scoped observations over the existing, canonical public route IDs.

No media relay or per-user IP history. IP lookup is local; tokens contain only
coarse country/subdivision/ASN. Network failures never create global tombstones.
"""
import base64
import hashlib
import hmac
import ipaddress
import json
import math
import os
import re
import sqlite3
import threading
import time
from pathlib import Path
from contextlib import contextmanager

from fastapi import APIRouter, BackgroundTasks, HTTPException, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

router = APIRouter(prefix='/api/v1/channel-catalog')
RETENTION_DAYS = 28
TOKEN_SECONDS = 7 * 86400
MAX_DAILY_VOTES = 20
_lock = threading.Lock()
_readers = {}


def migrate(conn):
    conn.execute('''CREATE TABLE IF NOT EXISTS route_network_health (
        digest TEXT NOT NULL, country TEXT NOT NULL, region TEXT NOT NULL,
        asn INTEGER NOT NULL, day INTEGER NOT NULL, reporter TEXT NOT NULL,
        successes REAL NOT NULL DEFAULT 0, failures REAL NOT NULL DEFAULT 0,
        first_byte_sum REAL NOT NULL DEFAULT 0, first_byte_count INTEGER NOT NULL DEFAULT 0,
        throughput_sum REAL NOT NULL DEFAULT 0, throughput_count INTEGER NOT NULL DEFAULT 0,
        playback_successes INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(digest,country,region,asn,day,reporter))''')
    conn.execute('CREATE INDEX IF NOT EXISTS network_health_lookup ON route_network_health(country,digest,day)')
    schema = conn.execute("SELECT sql FROM sqlite_master WHERE name='route_network_health'").fetchone()[0]
    conn.execute(schema.replace('CREATE TABLE route_network_health', 'CREATE TABLE IF NOT EXISTS relay_route_network_health'))
    conn.execute('CREATE INDEX IF NOT EXISTS relay_health_lookup ON relay_route_network_health(country,digest,day)')
    conn.execute('CREATE TABLE IF NOT EXISTS network_api_limits (origin TEXT PRIMARY KEY, hour INTEGER NOT NULL, count INTEGER NOT NULL)')
    conn.execute('CREATE TABLE IF NOT EXISTS network_probe_receipts (node TEXT NOT NULL, event_id TEXT NOT NULL, payload_hash TEXT NOT NULL, receipt TEXT NOT NULL, PRIMARY KEY(node,event_id))')


def normalize_profile(value):
    country, region, asn = value.get('countryCode'), value.get('regionCode'), value.get('asn')
    if country is None: country = 'ZZ'
    if not isinstance(country, str) or not re.fullmatch(r'[A-Z]{2}', country): raise ValueError('Invalid country')
    if region is None: region = ''
    if not isinstance(region, str) or not re.fullmatch(r'[A-Za-z0-9._-]{0,40}', region): raise ValueError('Invalid region')
    if asn is None: asn = 0
    if type(asn) is not int or not 0 <= asn <= 4294967295: raise ValueError('Invalid ASN')
    if country == 'ZZ': region, asn = '', 0
    return {'countryCode': country, 'regionCode': region, 'asn': asn,
            'networkId': f'{country}:{region or "*"}:{asn or "*"}'}


def _geo(path, address):
    """MMDB mmap readers are replaced only after a database inode changes."""
    try:
        import maxminddb
        stat = path.stat()
        stamp = (stat.st_ino, stat.st_mtime_ns, stat.st_size)
        with _lock:
            old = _readers.get(str(path))
            if old is None or old[0] != stamp:
                reader = maxminddb.open_database(str(path))
                _readers[str(path)] = (stamp, reader)
                if old: old[1].close()
            return _readers[str(path)][1].get(address) or {}
    except Exception:
        # Invalid/unavailable advisory data must never prevent playback.
        return {}


def resolve_address(address, data_dir):
    try:
        ip = ipaddress.ip_address(address)
        if not ip.is_global: raise ValueError()
    except ValueError:
        return normalize_profile({})
    directory = Path(os.environ.get('BOBTV_NETWORK_DB_DIR', Path(data_dir) / 'network-db'))
    city = _geo(directory / 'city.mmdb', str(ip))
    network = _geo(directory / 'asn.mmdb', str(ip))
    subdivision = city.get('subdivisions', [])
    subdivision = subdivision[0] if isinstance(subdivision, list) and subdivision else {}
    name = subdivision.get('names', {}).get('en', '')
    region = subdivision.get('iso_code') or ('n' + hashlib.sha256(name.encode()).hexdigest()[:12] if name else '')
    try:
        return normalize_profile({'countryCode': city.get('country', {}).get('iso_code'),
                                  'regionCode': region,
                                  'asn': network.get('autonomous_system_number', 0)})
    except (ValueError, TypeError, AttributeError):
        return normalize_profile({})


def request_profile(request, data_dir):
    # Uvicorn trusts only the loopback reverse proxy. Arbitrary country/ASN or
    # forwarding headers received directly from clients are never accepted here.
    from source_candidates import _attribution
    address, edge_country = _attribution(request)
    profile = resolve_address(address, data_dir)
    if profile['countryCode'] == 'ZZ' and edge_country:
        profile = normalize_profile({'countryCode': edge_country})
    return profile


def _secret(data_dir):
    path = Path(data_dir) / 'network-profile.key'
    with _lock:
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            # Exclusive creation prevents concurrent workers choosing new keys.
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            pass
        else:
            with os.fdopen(fd, 'wb') as output:
                output.write(os.urandom(32))
        value = path.read_bytes()
    if len(value) != 32: raise ValueError('Invalid network token key')
    return value


def issue_profile(profile, data_dir, now=None):
    now = int(time.time()) if now is None else now
    profile = normalize_profile(profile)
    payload = {**profile, 'issuedAt': now, 'expiresAt': now + TOKEN_SECONDS}
    raw = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
    body = base64.urlsafe_b64encode(raw).decode().rstrip('=')
    signature = hmac.new(_secret(data_dir), body.encode(), hashlib.sha256).hexdigest()
    return {**payload, 'token': body + '.' + signature,
            'attribution': {'name': 'DB-IP Lite', 'url': 'https://db-ip.com'},
            'approximate': True, 'schemaVersion': 1}


def verify_token(token, data_dir, now=None):
    if not isinstance(token, str) or len(token) > 1024: raise ValueError('Invalid network token')
    try:
        body, signature = token.split('.')
        expected = hmac.new(_secret(data_dir), body.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature, expected): raise ValueError()
        value = json.loads(base64.urlsafe_b64decode(body + '=' * (-len(body) % 4)))
        now = int(time.time()) if now is None else now
        issued, expires = value['issuedAt'], value['expiresAt']
        if type(issued) is not int or type(expires) is not int or issued > now + 60 or not issued <= now <= expires or expires - issued != TOKEN_SECONDS: raise ValueError()
        return normalize_profile(value)
    except (ValueError, KeyError, TypeError, UnicodeError):
        raise ValueError('Invalid or expired network token') from None


def record_health(conn, digest, reporter, event, data_dir, now=None):
    """Legacy/unattributed events stay in ZZ and cannot influence any country."""
    now = int(time.time()) if now is None else now
    profile = verify_token(event['networkToken'], data_dir, now) if event.get('networkToken') else normalize_profile({})
    success, failure = event.get('success', 0), event.get('failure', 0)
    if not all(type(v) is int and 0 <= v <= 10 for v in (success, failure)) or not success + failure:
        raise ValueError('Invalid health observation')
    kind = event.get('observation', 'legacy')
    if kind not in ('legacy', 'probe', 'playback', 'stall', 'manual'): raise ValueError('Invalid observation kind')
    metrics = {}
    for field, upper in [('firstByteMs', 120000), ('bytesPerSecond', 1000000000)]:
        value = event.get(field)
        if value is not None and (type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= upper):
            raise ValueError('Invalid health metric')
        metrics[field] = value
    table = health_table(event.get('transport', 'direct'))
    conn.execute(f'DELETE FROM {table} WHERE day<?', (now // 86400 - RETENTION_DAYS,))
    key = (digest, profile['countryCode'], profile['regionCode'], profile['asn'], now // 86400, reporter)
    conn.execute(f'INSERT OR IGNORE INTO {table}(digest,country,region,asn,day,reporter) VALUES(?,?,?,?,?,?)', key)
    old = conn.execute(f'SELECT successes,failures FROM {table} WHERE digest=? AND country=? AND region=? AND asn=? AND day=? AND reporter=?', key).fetchone()
    # Bound the influence of a noisy client, and distinguish byte probes from
    # confirmed decoded playback. Event receipts provide exact retry deduplication.
    budget = max(0, MAX_DAILY_VOTES - old['successes'] - old['failures'])
    positive = min(budget, success * (.35 if kind in ('probe', 'legacy') else 1))
    negative = min(budget - positive, failure)
    if positive + negative <= 0: return
    latency, rate = metrics['firstByteMs'], metrics['bytesPerSecond']
    conn.execute(f'''UPDATE {table} SET successes=successes+?,failures=failures+?,
        first_byte_sum=first_byte_sum+?,first_byte_count=first_byte_count+?,
        throughput_sum=throughput_sum+?,throughput_count=throughput_count+?,
        playback_successes=playback_successes+? WHERE digest=? AND country=? AND region=? AND asn=? AND day=? AND reporter=?''',
        (positive, negative, latency or 0, int(latency is not None), rate or 0,
         int(rate is not None), int(kind == 'playback' and success > 0), *key))


def health_table(transport):
    if transport == 'direct': return 'route_network_health'
    if transport == 'server-relay': return 'relay_route_network_health'
    raise ValueError('Invalid route transport')


def rank_routes(conn, urls, profile, now=None, transport='direct'):
    from catalog_inventory import validate_media_url
    now = int(time.time()) if now is None else now
    profile = normalize_profile(profile)
    table = health_table(transport)
    results = []
    for index, value in enumerate(dict.fromkeys(urls)):
        url = validate_media_url(value)
        digest = hashlib.sha256(url.encode()).hexdigest()
        route = conn.execute('SELECT blocked,deleted FROM routes WHERE digest=?', (digest,)).fetchone()
        if route is None: continue
        if route['blocked'] or route['deleted']: continue
        # A country boundary is absolute. Never borrow foreign negative votes,
        # even when there is no observation for this user's network.
        rows = conn.execute(f'SELECT * FROM {table} WHERE digest=? AND country=? AND day>=?',
                            (digest, profile['countryCode'], now // 86400 - RETENTION_DAYS)).fetchall() if profile['countryCode'] != 'ZZ' else []
        levels = []
        if profile['asn'] and profile['regionCode']:
            levels.append(('region-asn', [r for r in rows if r['region'] == profile['regionCode'] and r['asn'] == profile['asn']]))
        if profile['asn']: levels.append(('country-asn', [r for r in rows if r['asn'] == profile['asn']]))
        if profile['regionCode']: levels.append(('region', [r for r in rows if r['region'] == profile['regionCode']]))
        levels.append(('country', rows))
        scope, selected = next(((level, items) for level, items in levels if items), ('unknown', []))
        weighted_success = weighted_failure = latency_sum = latency_count = rate_sum = rate_count = 0.0
        for row in selected:
            decay = 1 / (1 + (now / 86400 - row['day']) / 7)
            weighted_success += row['successes'] * decay
            weighted_failure += row['failures'] * decay
            latency_sum += row['first_byte_sum'] * decay
            latency_count += row['first_byte_count'] * decay
            rate_sum += row['throughput_sum'] * decay
            rate_count += row['throughput_count'] * decay
        samples = weighted_success + weighted_failure
        reporters = len({row['reporter'] for row in selected})
        confidence = min(1, samples / 8) * min(1, reporters / 3)
        confidence *= {'region-asn': 1, 'country-asn': .85, 'region': .6, 'country': .4, 'unknown': 0}[scope]
        reliability = (weighted_success + 1) / (samples + 2)
        latency = latency_sum / latency_count if latency_count else None
        rate = rate_sum / rate_count if rate_count else None
        measured = reliability * .7 + (.5 if latency is None else 1 / (1 + latency / 1200)) * .15 + (.5 if rate is None else rate / (rate + 750000)) * .15
        score = .5 + (measured - .5) * confidence
        results.append({'url': url, 'score': round(score, 6), 'confidence': round(confidence, 4),
                        'scope': scope, 'reporters': reporters, 'samples': round(samples, 2),
                        'decodedPlayback': sum(r['playback_successes'] for r in selected),
                        'firstByteMs': None if latency is None else round(latency),
                        'bytesPerSecond': None if rate is None else round(rate), '_index': index})
    results.sort(key=lambda r: (-r['score'], r['_index']))
    for item in results: item.pop('_index')
    return results


@contextmanager
def inventory_reader(data_dir):
    """Ranking must never migrate or acquire the catalogue writer lock."""
    path = (Path(data_dir) / 'channel_inventory.sqlite3').resolve()
    conn = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=.25)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute('PRAGMA query_only=ON')
        yield conn
    finally:
        conn.close()


def _rate_limit(request, data_dir):
    from source_candidates import _attribution
    address, _ = _attribution(request)
    now = int(time.time())
    origin = hashlib.sha256(f'{now // 86400}:{address}'.encode()).hexdigest()
    directory = Path(data_dir)
    directory.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(directory / 'network-api-limits.sqlite3', timeout=1)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute('PRAGMA journal_mode=WAL')
        with conn:
            conn.execute('BEGIN IMMEDIATE')
            conn.execute('CREATE TABLE IF NOT EXISTS network_api_limits (origin TEXT PRIMARY KEY, hour INTEGER NOT NULL, count INTEGER NOT NULL)')
            conn.execute('CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY)')
            if not conn.execute("SELECT 1 FROM migrations WHERE name='inventory_limits_v1'").fetchone():
                # Keep the current hourly budget when switching storage. Reading
                # the WAL snapshot also works while a catalogue writer is busy.
                if (directory / 'channel_inventory.sqlite3').exists():
                    with inventory_reader(directory) as old:
                        rows = old.execute('SELECT origin,hour,count FROM network_api_limits WHERE hour>=?', (now // 3600 - 1,)).fetchall()
                    conn.executemany('INSERT OR IGNORE INTO network_api_limits VALUES(?,?,?)', rows)
                conn.execute("INSERT INTO migrations VALUES('inventory_limits_v1')")
            row = conn.execute('SELECT hour,count FROM network_api_limits WHERE origin=?', (origin,)).fetchone()
            count = row['count'] + 1 if row and row['hour'] == now // 3600 else 1
            if count > 600: raise HTTPException(429, 'Network ranking rate limit', headers={'Retry-After': '60'})
            conn.execute('DELETE FROM network_api_limits WHERE hour<?', (now // 3600 - 1,))
            conn.execute('INSERT INTO network_api_limits VALUES(?,?,?) ON CONFLICT(origin) DO UPDATE SET hour=excluded.hour,count=excluded.count', (origin, now // 3600, count))
    except sqlite3.OperationalError as error:
        if getattr(error, 'sqlite_errorcode', 0) & 255 in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED):
            raise HTTPException(503, 'Network state temporarily busy', headers={'Retry-After': '1'}) from None
        raise
    finally:
        conn.close()


@router.get('/network-profile')
def network_profile(request: Request):
    from catalog_inventory import DATA
    _rate_limit(request, DATA)
    return JSONResponse(issue_profile(request_profile(request, DATA), DATA), headers={'Cache-Control': 'no-store'})


@router.post('/rank')
async def network_rank(request: Request):
    from catalog_inventory import DATA, validate_media_url
    await run_in_threadpool(_rate_limit, request, DATA)
    if request.headers.get('content-type', '').split(';', 1)[0] != 'application/json': raise HTTPException(415)
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > 512 * 1024: raise HTTPException(413)
    try:
        payload = json.loads(body)
        transport = payload.get('transport', 'direct')
        health_table(transport)
        urls = payload['urls']
        if payload.get('schemaVersion') != 1 or not isinstance(urls, list) or not 1 <= len(urls) <= 200: raise ValueError()
        for url in urls: validate_media_url(url)
    except (ValueError, TypeError, KeyError):
        raise HTTPException(422, 'Invalid regional candidates') from None
    profile = request_profile(request, DATA)
    def calculate():
        started = time.monotonic()
        with inventory_reader(DATA) as conn:
            conn.set_progress_handler(lambda: int(time.monotonic() - started > 2), 2000)
            try:
                return rank_routes(conn, urls, profile, transport=transport)
            except sqlite3.OperationalError:
                raise HTTPException(503, 'Regional ranking temporarily busy', headers={'Retry-After': '60'}) from None
            finally:
                conn.set_progress_handler(None, 0)
    routes = await run_in_threadpool(calculate)
    return JSONResponse({'schemaVersion': 1, 'profile': issue_profile(profile, DATA), 'routes': routes}, headers={'Cache-Control': 'no-store'})


def authorized_probe(request, node_id):
    """Only administrator-registered probe nodes can approve new public routes."""
    path = Path(os.environ.get('BOBTV_PROBE_CONFIG', '/etc/bobtv/network-probes.json'))
    try:
        config = json.loads(path.read_text())['nodes'].get(node_id)
        authorization = request.headers.get('authorization', '')
        if not config or config.get('enabled') is not True or not authorization.startswith('Bearer '): raise ValueError()
        token = authorization[7:]
        if not 32 <= len(token) <= 256: raise ValueError()
        if not hmac.compare_digest(hashlib.sha256(token.encode()).hexdigest(), config['keySha256']): raise ValueError()
        profile = normalize_profile(config)
        if profile['countryCode'] == 'ZZ': raise ValueError()
        return {**profile, 'canApprove': config.get('canApprove') is True}
    except (OSError, ValueError, KeyError, TypeError):
        raise HTTPException(401, 'Unregistered network probe') from None


@router.get('/probe-targets')
def probe_targets(request: Request, nodeId: str):
    from catalog_inventory import DATA, database
    profile = authorized_probe(request, nodeId)
    _rate_limit(request, DATA)
    with database(DATA) as conn:
        rows = conn.execute('''SELECT r.url FROM routes r WHERE r.blocked=0 AND r.deleted=0
            AND NOT EXISTS(SELECT 1 FROM route_network_health h WHERE h.digest=r.digest
                AND h.country=? AND h.region=? AND h.asn=? AND h.day>=?)
            ORDER BY r.success_at IS NULL DESC,r.group_name='中国 / 央视' DESC,r.received DESC LIMIT 100''',
            (profile['countryCode'], profile['regionCode'], profile['asn'], int(time.time()) // 86400 - 1)).fetchall()
    return JSONResponse({'schemaVersion': 1, 'urls': [r['url'] for r in rows]}, headers={'Cache-Control': 'no-store'})


def ingest_probe_results(results, node_id, profile, data_dir):
    from catalog_inventory import database, validate_media_url
    if not isinstance(results, list) or not 1 <= len(results) <= 100: raise ValueError('Invalid probe batch')
    normalized = []
    for result in results:
        if not isinstance(result, dict) or not re.fullmatch(r'[a-f0-9-]{16,80}', result.get('id', '')) or type(result.get('success')) is not bool:
            raise ValueError('Invalid probe result')
        url = validate_media_url(result.get('url'))
        kind = result.get('observation', 'probe')
        if kind not in ('probe', 'playback'): raise ValueError('Invalid probe evidence')
        for name, upper in [('firstByteMs', 120000), ('bytesPerSecond', 1000000000)]:
            value = result.get(name)
            if value is not None and (type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= upper):
                raise ValueError('Invalid probe metric')
        normalized.append({**result, 'url': url, 'observation': kind})
    token = issue_profile(profile, data_dir)['token']
    reporter = hashlib.sha256(('probe:' + node_id).encode()).hexdigest()
    receipts = []
    with database(data_dir) as conn:
        for item in normalized:
            digest = hashlib.sha256(item['url'].encode()).hexdigest()
            payload_hash = hashlib.sha256(json.dumps(item, sort_keys=True).encode()).hexdigest()
            saved = conn.execute('SELECT payload_hash,receipt FROM network_probe_receipts WHERE node=? AND event_id=?', (node_id, item['id'])).fetchone()
            if saved:
                if saved['payload_hash'] != payload_hash: raise ValueError('Probe ID reused with different content')
                receipts.append(json.loads(saved['receipt']))
                continue
            route = conn.execute('SELECT blocked,deleted FROM routes WHERE digest=?', (digest,)).fetchone()
            receipt = {'id': item['id'], 'status': 'rejected'}
            if route is not None and not route['blocked'] and not route['deleted']:
                record_health(conn, digest, reporter, {
                    'networkToken': token, 'observation': item['observation'],
                    'success': 2 if item['success'] and item['observation'] == 'playback' else int(item['success']),
                    'failure': int(not item['success']),
                    'firstByteMs': item.get('firstByteMs'), 'bytesPerSecond': item.get('bytesPerSecond'),
                }, data_dir)
                if item['success'] and profile.get('canApprove'):
                    now = int(time.time())
                    conn.execute('UPDATE routes SET success_at=?,checked_at=?,failures=0 WHERE digest=?', (now, now, digest))
                receipt['status'] = 'applied'
            conn.execute('INSERT INTO network_probe_receipts VALUES(?,?,?,?)', (node_id, item['id'], payload_hash, json.dumps(receipt)))
            receipts.append(receipt)
    return {'schemaVersion': 1, 'receipts': receipts}


@router.post('/probe-results')
async def probe_results(request: Request, background_tasks: BackgroundTasks):
    from catalog_inventory import DATA, _publish_changes
    if request.headers.get('content-type', '').split(';', 1)[0] != 'application/json': raise HTTPException(415)
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > 256 * 1024: raise HTTPException(413)
    try:
        payload = json.loads(body)
        if payload.get('schemaVersion') != 1 or not isinstance(payload.get('nodeId'), str): raise ValueError()
    except (ValueError, TypeError, AttributeError):
        raise HTTPException(422, 'Invalid network probe batch') from None
    profile = authorized_probe(request, payload['nodeId'])
    _rate_limit(request, DATA)
    try:
        result = ingest_probe_results(payload.get('results'), payload['nodeId'], profile, DATA)
    except (ValueError, TypeError):
        raise HTTPException(422, 'Invalid network probe evidence') from None
    background_tasks.add_task(_publish_changes)
    return JSONResponse(result, status_code=202)
