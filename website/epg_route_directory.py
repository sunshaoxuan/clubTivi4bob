"""Exact-route radio metadata, independent of AI admission and never approval.

Only one already selected public catalogue channel is checked. The sole network
destination is the documented Radio Browser by-URL API. Streams, record homepages,
click counters and country-wide lists are never requested. Untrusted directory
labels remain partial evidence; this module cannot change identity or EPG data.
"""
import hashlib
import ipaddress
import json
import re
import time
import urllib.request
from urllib.parse import urlencode, urlsplit

import epg_channel_research as queue
from epg_channel_research_worker import protected_ids
from epg_ingest import EpgError, NoRedirect

ENDPOINT = 'https://de1.api.radio-browser.info/json/stations/byurl'
MAX_BYTES = 65536
TTL = 21600
FIELDS = ('stationuuid', 'name', 'countrycode', 'state', 'language', 'languagecodes',
          'lastchangetime_iso8601', 'lastchecktime_iso8601')


def migrate(conn):
    conn.executescript('''
      CREATE TABLE IF NOT EXISTS epg_route_directory_cache(
        route_hash TEXT PRIMARY KEY,checked_at INTEGER NOT NULL,next_retry INTEGER NOT NULL,
        failures INTEGER NOT NULL,result TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS epg_checkpoints(name TEXT PRIMARY KEY,value TEXT NOT NULL);
    ''')


def recent_target_ids(conn, now, channels=None, paths=None):
    """Exclude ineligible/recent targets without changing model retry floors."""
    rows = conn.execute('''SELECT a.channel_id,a.evidence FROM epg_channel_research_audit a
      JOIN epg_channel_research_jobs j ON j.channel_id=a.channel_id AND j.identity_hash=a.identity_hash
      WHERE a.event='exact_route_directory_observation' AND a.checked_at>=?
      ORDER BY a.id DESC LIMIT 500''', (now - 86400,)).fetchall()
    seen, waiting = set(), {c['id'] for c in (channels or [])
                            if selected_route(c, paths[c['id']]) is None}
    for row in rows:
        if row['channel_id'] in seen:
            continue
        seen.add(row['channel_id'])
        if json.loads(row['evidence']).get('nextRetryAtUtc', 0) > now:
            waiting.add(row['channel_id'])
    return waiting


def selected_route(channel, path):
    # Classification is a selection hint, not evidence of country or identity.
    if not any(part in {'广播', '廣播', '电台', '電臺', 'Radio'} for part in path):
        return None
    routes = channel.get('routes')
    if not isinstance(routes, list) or len(routes) != 1:
        return None
    route = routes[0].get('url') if isinstance(routes[0], dict) else None
    if (not isinstance(route, str) or not 1 <= len(route) <= 2048
            or any(ord(char) <= 32 for char in route)):
        return None
    parsed = urlsplit(route)
    try:
        port = parsed.port
    except ValueError:
        return None
    if (parsed.scheme not in {'http', 'https'} or not parsed.hostname or not parsed.path
            or parsed.username or parsed.password or parsed.query or parsed.fragment or port
            or '.' not in parsed.hostname or parsed.hostname.endswith(('.local', '.internal', '.localhost'))):
        return None
    try:
        ipaddress.ip_address(parsed.hostname)
    except ValueError:
        return route
    return None


def request_url(route):
    return ENDPOINT + '?' + urlencode({'url': route})


def fetch_selected(route, *, opener=None, clock=time.monotonic):
    if opener is None:
        from process_channel_inventory import _HTTPSHandler
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(), _HTTPSHandler())
    url = request_url(route)
    req = urllib.request.Request(url, headers={'User-Agent': 'BobTV-Channel-Identity/1',
        'Accept': 'application/json', 'Accept-Encoding': 'identity'})
    started = clock()
    with opener.open(req, timeout=6) as response:
        if response.code != 200 or response.geturl() != url:
            raise EpgError('route_directory_access_rejected')
        if (response.headers.get('Content-Encoding', 'identity').lower() != 'identity'
                or response.headers.get('Content-Type', '').split(';')[0].lower() != 'application/json'):
            raise EpgError('route_directory_type_rejected')
        declared = response.headers.get('Content-Length', '')
        if declared.isdecimal() and int(declared) > MAX_BYTES:
            raise EpgError('route_directory_size_limit')
        chunks, size = [], 0
        while True:
            if clock() - started > 8:
                raise EpgError('route_directory_read_timeout')
            chunk = response.read1(8192)
            if not chunk:
                break
            size += len(chunk)
            if size > MAX_BYTES:
                raise EpgError('route_directory_size_limit')
            chunks.append(chunk)
    body = b''.join(chunks)
    values = json.loads(body)
    if not isinstance(values, list) or len(values) > 20:
        raise EpgError('route_directory_invalid_response')
    records = []
    for value in values:
        # A resolved alternative URL or a similar name does not establish this
        # exact catalogue route. Never follow links supplied in these records.
        if not isinstance(value, dict) or value.get('url') != route:
            continue
        record = {}
        for key in FIELDS:
            field = value.get(key, '')
            if not isinstance(field, str) or len(field) > 256 or any(ord(c) < 32 for c in field):
                raise EpgError('route_directory_invalid_field')
            record[key] = field
        records.append(record)
    return {'state': 'exact_route_metadata' if records else 'no_exact_route_metadata',
            'bodySha256': hashlib.sha256(body).hexdigest(), 'bodyBytes': len(body), 'records': records}


def _eligible(conn, expected, now):
    row = conn.execute('SELECT * FROM epg_channel_research_jobs WHERE channel_id=?',
                       (expected['channel_id'],)).fetchone()
    if (row is None or not row['active'] or row['identity_hash'] != expected['identity_hash']
            or row['payload'] != expected['payload'] or row['identity_evidence']
            or row['state'] != 'pending_identity' or row['next_retry'] > now
            or row['lease_until'] > now or row['channel_id'] in protected_ids(conn)):
        return None
    return row


def check_selected(conn, expected, channel, path, now, *, fetcher=fetch_selected,
                   reload_selected=None):
    """One bounded request or cached result; all channel retry floors survive.

    The caller holds the existing auto-search process lock. A second catalogue
    and mapping check rejects in-flight drift before any evidence is attached.
    Network waits never hold the SQLite writer. Cache and audit use the existing
    authoritative database; no mapping, approval or programme table is written.
    """
    migrate(conn)
    route = selected_route(channel, path)
    if route is None:
        return {'state': 'ineligible_exact_route', 'networkRequests': 0}
    payload = {key: channel.get(key) for key in ('id', 'name', 'epgId', 'countryCode', 'regionCode')}
    digest = hashlib.sha256(route.encode()).hexdigest()
    payload.update(categoryPath=path, routeSha256=[digest])
    if (queue.encoded(payload) != expected['payload']
            or hashlib.sha256(queue.encoded(payload).encode()).hexdigest() != expected['identity_hash']
            or _eligible(conn, expected, now) is None):
        return {'state': 'stale_target_rejected', 'networkRequests': 0}
    cached = conn.execute('SELECT * FROM epg_route_directory_cache WHERE route_hash=?', (digest,)).fetchone()
    if cached and cached['next_retry'] > now:
        # The same batch-source observation can belong to another selected
        # target without another download. Keep its original fetch timestamp
        # and recompute catalogue conflicts for this target, never the first.
        previous = conn.execute('''SELECT evidence FROM epg_channel_research_audit
          WHERE channel_id=? AND identity_hash=? AND event='exact_route_directory_observation'
          ORDER BY id DESC LIMIT 1''', (expected['channel_id'], expected['identity_hash'])).fetchone()
        if previous is None or json.loads(previous[0]).get('checkedAtUtc') != cached['checked_at']:
            conn.execute('BEGIN IMMEDIATE')
            try:
                row = _eligible(conn, expected, now)
                if row is None:
                    conn.rollback()
                    return {'state': 'stale_target_rejected', 'networkRequests': 0}
                retained = json.loads(cached['result'])
                retained.update(cacheReused=True, observedAtUtc=now, networkRequests=0,
                    catalogueCountryConflict=any(code != channel.get('countryCode')
                        for code in retained.get('directoryCountryCodes', [])))
                queue._audit(conn, row, now, 'exact_route_directory_observation', retained)
                conn.commit()
            except BaseException:
                conn.rollback()
                raise
        return {'state': 'cached_or_backoff', 'networkRequests': 0, 'nextRetryAtUtc': cached['next_retry']}
    control_row = conn.execute("SELECT value FROM epg_checkpoints WHERE name='route_directory_control'").fetchone()
    control = json.loads(control_row[0]) if control_row else {}
    if control.get('nextRetryAtUtc', 0) > now:
        return {'state': 'directory_provider_backoff', 'networkRequests': 0,
                'nextRetryAtUtc': control['nextRetryAtUtc']}
    try:
        value = fetcher(route)
        if (not isinstance(value, dict) or value.get('state') not in {'exact_route_metadata', 'no_exact_route_metadata'}
                or not isinstance(value.get('records'), list) or len(value['records']) > 20
                or not re.fullmatch('[a-f0-9]{64}', str(value.get('bodySha256', '')))
                or type(value.get('bodyBytes')) is not int or not 0 <= value['bodyBytes'] <= MAX_BYTES):
            raise EpgError('route_directory_invalid_result')
        failures = 0
    except (OSError, TimeoutError, ValueError, TypeError, KeyError):
        value = {'state': 'bounded_directory_check_failed', 'safeError': 'route_directory_unavailable', 'records': []}
        failures = min(5, max(control.get('failures', 0), cached['failures'] if cached else 0) + 1)
    next_retry = now + (min(86400, 3600 * 2 ** (failures - 1)) if failures else TTL)
    if reload_selected is not None and reload_selected() != expected['identity_hash']:
        return {'state': 'stale_target_rejected', 'networkRequests': 1}
    conn.execute('BEGIN IMMEDIATE')
    try:
        row = _eligible(conn, expected, now)
        if row is None:
            conn.rollback()
            return {'state': 'stale_target_rejected', 'networkRequests': 1}
        countries = sorted({r.get('countrycode', '') for r in value['records']
                            if re.fullmatch('[A-Z]{2}', str(r.get('countrycode', '')))})
        value.update(sourceUrl=ENDPOINT, requestedRouteSha256=digest,
            checkedAtUtc=now, nextRetryAtUtc=next_retry, directoryCountryCodes=countries,
            catalogueCountryConflict=any(code != channel.get('countryCode') for code in countries),
            identityApproved=False, classificationConfirmed=False, programmeSearchPerformed=False,
            networkRequests=1, aiRequests=0, newMappings=0, newGrants=0, published=False)
        conn.execute('INSERT OR REPLACE INTO epg_route_directory_cache VALUES(?,?,?,?,?)',
                     (digest, now, next_retry, failures, queue.encoded(value)))
        conn.execute('INSERT OR REPLACE INTO epg_checkpoints VALUES(?,?)', ('route_directory_control',
            queue.encoded({'failures': failures, 'nextRetryAtUtc': next_retry if failures else 0,
                           'safeError': value.get('safeError'), 'checkedAtUtc': now})))
        queue._audit(conn, row, now, 'exact_route_directory_observation', value)
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    return {key: value[key] for key in ('state', 'networkRequests', 'aiRequests', 'nextRetryAtUtc',
        'catalogueCountryConflict', 'identityApproved', 'newMappings', 'newGrants')}
