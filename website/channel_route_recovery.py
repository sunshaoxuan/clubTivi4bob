"""Channel-bound public-route recovery, independent of clients and AI uptime.

Failures request research, never global deletion. Only a reviewed identity and
media-use grant can admit a decoded replacement into the authoritative catalog.
"""
import copy
from datetime import datetime, timezone
import fcntl
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import time

from catalog_inventory import database as inventory_db, validate_media_url
from publish_channel_catalog import publish, _atomic_write
from route_identity import canonical_route_url
from server_jobs import DATA, database as task_db

PROFILES = Path(os.environ.get('BOBTV_ROUTE_RECOVERY_PROFILES',
    Path(__file__).with_name('channel_route_recovery_profiles.json')))
MAX_QUEUE = 500
MAX_HOURLY = 6


def catalog(directory):
    root = Path(directory) / 'channel-catalog'
    manifest = json.loads((root / 'manifest.json').read_text())
    raw = (root / 'snapshots' / (manifest['sha256'] + '.json.gz')).read_bytes()
    if len(raw) > 32 * 1024 * 1024 or hashlib.sha256(raw).hexdigest() != manifest['sha256']:
        raise ValueError('catalog_integrity')
    with gzip.GzipFile(fileobj=io.BytesIO(raw)) as stream:
        decoded = stream.read(64 * 1024 * 1024 + 1)
    if len(decoded) > 64 * 1024 * 1024:
        raise ValueError('catalog_expansion_limit')
    payload = json.loads(decoded)
    return manifest, payload


def category_path(payload, identity):
    categories = {c['id']: c for c in payload['categories']}
    result, seen = [], set()
    while identity:
        if identity in seen or len(seen) >= 8:
            raise ValueError('catalog_category_cycle')
        seen.add(identity)
        item = categories[identity]
        result.insert(0, item['name'])
        identity = item['parentId']
    return result


def identity(payload, channel, *, include_routes=True):
    value = {k: channel.get(k) for k in
             ('id', 'name', 'countryCode', 'regionCode', 'epgId', 'mergeId')}
    value['categoryPaths'] = sorted(category_path(payload, key) for key in
                                    channel.get('categoryIds', [channel['categoryId']]))
    if include_routes:
        value['routes'] = sorted(canonical_route_url(r['url']) for r in channel['routes'])
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).hexdigest()


def schema(conn):
    conn.execute('''CREATE TABLE IF NOT EXISTS route_recovery_audit (
        id INTEGER PRIMARY KEY, job_id TEXT NOT NULL, checked_at INTEGER NOT NULL,
        event TEXT NOT NULL, evidence TEXT NOT NULL)''')
    conn.execute('CREATE INDEX IF NOT EXISTS route_recovery_audit_job ON route_recovery_audit(job_id,id)')


def binding_schema(conn):
    conn.execute('''CREATE TABLE IF NOT EXISTS route_recovery_bindings (
        digest TEXT PRIMARY KEY, channel_id TEXT NOT NULL,
        metadata_hash TEXT NOT NULL, source_url TEXT NOT NULL, created INTEGER NOT NULL)''')


def record_failure_signal(conn, row, event, now):
    if (row['blocked'] or row['deleted'] or event.get('failure', 0) <= 0
            or event.get('observation') not in ('probe', 'stall')):
        return
    conn.execute('CREATE TABLE IF NOT EXISTS route_recovery_signals (digest TEXT PRIMARY KEY,failed_at INTEGER NOT NULL)')
    conn.execute('INSERT INTO route_recovery_signals VALUES(?,?) ON CONFLICT(digest) DO UPDATE SET failed_at=excluded.failed_at',
                 (row['digest'], now))


def enqueue(channel_id, failed_url=None, directory=DATA, now=None, reason='client_exhausted'):
    now = int(time.time()) if now is None else now
    manifest, payload = catalog(directory)
    channel = next((c for c in payload['channels'] if c['id'] == channel_id), None)
    if channel is None:
        raise ValueError('public_channel_required')
    if failed_url is not None:
        failed_url = validate_media_url(failed_url)
        if failed_url not in {canonical_route_url(r['url']) for r in channel['routes']}:
            raise ValueError('public_channel_route_mismatch')
        with inventory_db(directory) as conn:
            row = conn.execute('SELECT blocked,deleted FROM routes WHERE url=?', (failed_url,)).fetchone()
            if row and (row['blocked'] or row['deleted']):
                raise ValueError('retired_route_not_recoverable')
    target = {'channelId': channel_id, 'identityHash': identity(payload, channel)}
    encoded = json.dumps(target, sort_keys=True, separators=(',', ':'))
    key = hashlib.sha256(('recover\0' + encoded).encode()).hexdigest()
    with task_db(directory) as conn:
        schema(conn)
        conn.execute('BEGIN IMMEDIATE')
        old = conn.execute('SELECT * FROM jobs WHERE id=?', (key,)).fetchone()
        if old:
            # Repeated failures cannot reset an existing lease or retry floor.
            return dict(old)
        if conn.execute("SELECT count(*) FROM jobs WHERE kind='recover' AND (state='running' OR (state='queued' AND next_attempt<=?))", (now,)).fetchone()[0] >= MAX_QUEUE:
            raise ValueError('recovery_queue_full')
        conn.execute("INSERT INTO jobs(id,kind,payload,state,created,updated) VALUES(?,'recover',?,'queued',?,?)",
                     (key, encoded, now, now))
        conn.execute('INSERT INTO route_recovery_audit(job_id,checked_at,event,evidence) VALUES(?,?,?,?)',
                     (key, now, 'enqueued', json.dumps({'channelId': channel_id,
                      'catalogVersion': manifest['version'], 'reason': reason})))
        return dict(conn.execute('SELECT * FROM jobs WHERE id=?', (key,)).fetchone())


def seed(directory=DATA, now=None, limit=10):
    """A failed last route or all recently failed alternatives needs research.

    Local network evidence can enqueue research without revoking other networks'
    routes. No favorites, reporter identities, IPs or client search terms travel.
    """
    now = int(time.time()) if now is None else now
    _, payload = catalog(directory)
    with inventory_db(directory) as conn:
        rows = {r['url']: dict(r) for r in conn.execute('SELECT * FROM routes')}
        exists = conn.execute("SELECT 1 FROM sqlite_master WHERE name='route_recovery_signals'").fetchone()
        network_failed = {r[0] for r in conn.execute('SELECT digest FROM route_recovery_signals WHERE failed_at>=?',
                           (now - 3 * 86400,))} if exists else set()
    with task_db(directory) as conn:
        existing = {r['id'] for r in conn.execute("SELECT id FROM jobs WHERE kind='recover'")}
    added = []
    for channel in payload['channels']:
        live, failed = [], []
        for route in channel['routes']:
            row = rows.get(canonical_route_url(route['url']))
            if not row or row['blocked'] or row['deleted']:
                continue
            live.append(route['url'])
            if ((row['failures'] > 0 and (row['checked_at'] or 0) >= now - 3 * 86400)
                    or row['digest'] in network_failed):
                failed.append(route['url'])
        if live and len(failed) == len(live):
            target = json.dumps({'channelId': channel['id'], 'identityHash': identity(payload, channel)},
                                sort_keys=True, separators=(',', ':'))
            key = hashlib.sha256(('recover\0' + target).encode()).hexdigest()
            if key not in existing:
                try:
                    added.append(enqueue(channel['id'], failed[0], directory, now, 'no_healthy_alternative'))
                except ValueError as error:
                    if str(error) == 'recovery_queue_full':
                        break  # A full inbox must still consume its existing jobs.
                    if str(error) in ('public_channel_required', 'public_channel_route_mismatch', 'retired_route_not_recoverable'):
                        continue  # A concurrent catalog edit will be reseeded later.
                    raise
                existing.add(key)
        if len(added) >= max(1, min(25, limit)):
            break
    return added


def profiles(path=PROFILES):
    value = json.loads(Path(path).read_text())
    if value.get('schemaVersion') != 1 or not isinstance(value.get('channels'), list):
        raise ValueError('recovery_profile_schema')
    return value['channels']


def matching_profile(payload, channel, entries):
    expected = identity(payload, channel, include_routes=False)
    return next((p for p in entries if p.get('channelId') == channel['id']
                 and p.get('metadataHash') == expected), None)


def can_publish(profile, candidate):
    from urllib.parse import urlsplit
    from route_recovery_search import public_url
    if not profile or profile.get('identityVerified') is not True or profile.get('publicationAllowed') is not True:
        return False
    required = ('operator', 'countryCode', 'channelNumber', 'language', 'feedVariant', 'broadcastType')
    if any(not isinstance(profile.get(k), str) or not profile[k] for k in required):
        return False
    for key in ('identityEvidenceUrls', 'authorizationEvidenceUrls', 'approvedDocuments'):
        values = profile.get(key)
        if not isinstance(values, list) or not values or len(values) > 20:
            return False
        try:
            if any(not isinstance(value, str) or public_url(value, document=True) != value for value in values):
                return False
        except (ValueError, TypeError):
            return False
    if profile.get('broadcastType') not in ('television', 'radio'):
        return False
    # A repository licence alone never authorizes redistribution of its media.
    return (candidate.get('countryCode') == profile['countryCode']
            and candidate['source'] in profile.get('approvedDocuments', [])
            and urlsplit(candidate['url']).hostname in profile.get('mediaHosts', []))


def apply_bindings(channels, previous, conn):
    """Preserve the reviewed target ID across subsequent ordinary publications."""
    binding_schema(conn)
    if not previous:
        return channels
    old = {c['id']: c for c in previous['channels']}
    grouped = {}
    for row in conn.execute('''SELECT b.* FROM route_recovery_bindings b JOIN routes r
            ON r.digest=b.digest WHERE r.blocked=0 AND r.deleted=0 AND r.transferred=0
            AND r.manual_name=0 AND r.manual_category=0'''):
        target = old.get(row['channel_id'])
        if target and identity(previous, target, include_routes=False) == row['metadata_hash']:
            grouped.setdefault(target['id'], set()).add(row['digest'])
    result = copy.deepcopy(channels)
    for key, digests in grouped.items():
        target = old[key]
        owned = {canonical_route_url(r['url']) for r in target['routes']}
        selected = {}
        for channel in result:
            keep = []
            for route in channel['routes']:
                url = canonical_route_url(route['url'])
                if url in owned or hashlib.sha256(url.encode()).hexdigest() in digests:
                    selected[url] = route
                else:
                    keep.append(route)
            channel['routes'] = keep
        if selected:
            result = [c for c in result if c['routes'] and c['id'] != key]
            ordered = [selected.pop(url) for url in sorted(owned) if url in selected]
            result.append({**target, 'routes': ordered + list(selected.values())})
    return result


def bind_deployed_matcher(conn, channel, digest):
    """Respect the persistent matcher already deployed on the authority node.

    Older source checkouts use apply_bindings instead. Never replace the deployed
    publisher, migrate its tables or silently reassign an existing route owner.
    """
    if not conn.execute("SELECT 1 FROM sqlite_master WHERE name='catalog_channel_routes'").fetchone():
        return
    columns = {row[1] for row in conn.execute('PRAGMA table_info(catalog_channel_routes)')}
    if columns != {'digest', 'channel_id', 'state', 'reason', 'signature'}:
        raise ValueError('runtime_binding_incompatible')
    entity = conn.execute('SELECT metadata FROM catalog_channels WHERE id=?', (channel['id'],)).fetchone()
    metadata = json.loads(entity[0]) if entity else {}
    if any(metadata.get(key) != channel.get(key) for key in
           ('id', 'name', 'countryCode', 'regionCode', 'epgId', 'mergeId')):
        raise ValueError('runtime_binding_identity_changed')
    conn.execute("INSERT INTO catalog_channel_routes(digest,channel_id,state,reason,signature) VALUES(?,?,'assigned','reviewed-route-recovery','')",
                 (digest, channel['id']))


def admit(directory, target_hash, channel_id, candidates, profile, now):
    """No network within the catalog/DB transaction; snapshot precedes manifest."""
    directory = Path(directory)
    path = directory / 'channel-catalog/manifest.json'
    with (directory / 'catalog-process.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        old_manifest = path.read_bytes()
        manifest, payload = catalog(directory)
        channel = next((c for c in payload['channels'] if c['id'] == channel_id), None)
        if not channel or identity(payload, channel) != target_hash:
            raise ValueError('recovery_identity_changed')
        if matching_profile(payload, channel, [profile] if profile else []) is None:
            raise ValueError('recovery_profile_changed')
        known = {canonical_route_url(r['url']) for c in payload['channels'] for r in c['routes']}
        added = []
        try:
            with inventory_db(directory) as conn:
                binding_schema(conn)
                for candidate in candidates:
                    url = validate_media_url(candidate['url'])
                    if url in known or not can_publish(profile, candidate) or candidate.get('decoded') is not True:
                        continue
                    digest = hashlib.sha256(url.encode()).hexdigest()
                    row = conn.execute('SELECT blocked,deleted FROM routes WHERE digest=?', (digest,)).fetchone()
                    if row and (row['blocked'] or row['deleted']):
                        continue
                    if row is not None:
                        continue  # Another service/manual owner is never silently reassigned.
                    group = ' / '.join(category_path(payload, channel['categoryId']))
                    conn.execute('''INSERT INTO routes(digest,name,url,group_name,source,epg_id,logo_url,
                        received,checked_at,success_at) VALUES(?,?,?,?,?,?,?,?,?,?)''',
                        (digest, channel['name'], url, group, candidate['source'][:128],
                         channel.get('epgId'), channel.get('logoUrl'), now, now, now))
                    conn.execute('INSERT INTO route_recovery_bindings VALUES(?,?,?,?,?)',
                        (digest, channel_id, identity(payload, channel, include_routes=False), candidate['source'], now))
                    bind_deployed_matcher(conn, channel, digest)
                    channel['routes'].append({'id': 'route-' + digest[:24], 'url': url,
                        'source': candidate['source'][:128], 'healthScore': .8, 'revision': 0,
                        'lastPlayableAt': datetime.fromtimestamp(now, timezone.utc).isoformat().replace('+00:00', 'Z')})
                    added.append(digest)
                    known.add(url)
                if added:
                    payload['version'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%fZ')
                    manifest = publish(payload, directory)
        except BaseException:
            if path.read_bytes() != old_manifest:
                _atomic_write(path, old_manifest)
            raise
    return {'published': bool(added), 'added': len(added), 'catalogVersion': manifest['version']}


def claim(directory, now):
    with task_db(directory) as conn:
        schema(conn)
        conn.execute('BEGIN IMMEDIATE')
        conn.execute("UPDATE jobs SET state='queued',next_attempt=?,error_code='recovery_interrupted' WHERE kind='recover' AND state='running' AND updated<?",
                     (now + 300, now - 180))
        if conn.execute("SELECT count(*) FROM starts WHERE kind='recover' AND started>?", (now - 3600,)).fetchone()[0] >= MAX_HOURLY:
            return None
        last = conn.execute("SELECT j.attempts FROM starts s JOIN jobs j ON j.id=s.job_id WHERE s.kind='recover' ORDER BY s.started DESC,s.rowid DESC LIMIT 1").fetchone()
        # Alternate first research and due retries when both lanes have work.
        # Neither an endless fresh-failure stream nor old retries owns the head.
        fresh_first = last is None or last[0] > 1
        row = conn.execute("SELECT * FROM jobs WHERE kind='recover' AND state='queued' AND next_attempt<=? ORDER BY CASE WHEN attempts=0 THEN ? ELSE ? END,next_attempt,created,id LIMIT 1",
                           (now, 0 if fresh_first else 1, 1 if fresh_first else 0)).fetchone()
        if row is None:
            return None
        conn.execute("UPDATE jobs SET state='running',attempts=attempts+1,updated=? WHERE id=?", (now, row['id']))
        conn.execute('INSERT INTO starts VALUES(?,?,?)', (row['id'], 'recover', now))
        return dict(conn.execute('SELECT * FROM jobs WHERE id=?', (row['id'],)).fetchone())


def run(directory=DATA, *, now=None, search=None, decoder=None, profile_path=PROFILES, limit=1):
    from route_recovery_search import search_channel, decode_candidate, SearchDeferred
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / 'route-recovery-worker.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {'state': 'already_running'}
        now = int(time.time()) if now is None else now
        seed(directory, now)
        completed = []
        for _ in range(max(1, min(5, limit))):
            job = claim(directory, now)
            if not job:
                break
            outcome, retry, code = {}, None, None
            try:
                target = json.loads(job['payload'])
                _, payload = catalog(directory)
                channel = next((c for c in payload['channels'] if c['id'] == target['channelId']), None)
                if channel is None or identity(payload, channel) != target['identityHash']:
                    outcome = {'state': 'identity_changed', 'added': 0}
                else:
                    profile = matching_profile(payload, channel, profiles(profile_path))
                    findings = (search or search_channel)(channel, profile, directory)
                    candidates, decisions, media_checks = [], [], 0
                    existing = {canonical_route_url(r['url']) for c in payload['channels'] for r in c['routes']}
                    for candidate in findings.get('candidates', [])[:5]:
                        decision = {**candidate, 'checkedAt': now}
                        if candidate['url'] in existing:
                            decisions.append({**decision, 'decision': 'existing_route'})
                            continue
                        if not can_publish(profile, candidate):
                            decisions.append({**decision, 'decision': 'identity_or_media_permission_unverified'})
                            continue
                        if media_checks >= 2:
                            decisions.append({**decision, 'decision': 'decode_budget_deferred'})
                            continue
                        media_checks += 1
                        try:
                            decoded = (decoder or decode_candidate)(candidate['url'], profile)
                        except SearchDeferred:
                            raise
                        except (OSError, ValueError):
                            decoded = False
                        decisions.append({**decision, 'decision': 'decoded' if decoded else 'decode_failed'})
                        if decoded:
                            candidates.append({**candidate, 'decoded': True})
                    if candidates:
                        outcome = {'state': 'recovered', **admit(directory, target['identityHash'],
                            channel['id'], candidates, profile, now)}
                    else:
                        outcome = {'state': 'needs_review' if findings.get('candidates') else 'no_candidates', 'added': 0}
                        if findings.get('sources') and not any(s.get('state') in ('checked', 'cached') for s in findings['sources']):
                            outcome = {'state': 'deferred', 'added': 0, 'errorCode': 'search_sources_unavailable'}
                            code = 'search_sources_unavailable'
                    outcome.update({k: findings.get(k, []) for k in ('queries', 'sources', 'candidates')})
                    outcome['decisions'] = decisions
                    outcome['identityConfirmed'] = bool(profile and profile.get('identityVerified'))
                    if not outcome.get('added'):
                        retry = now + min(86400, 1800 * 2 ** min(job['attempts'] - 1, 6))
            except SearchDeferred as error:
                code, retry = error.code, max(now + 300, error.retry_at)
                outcome = {'state': 'deferred', 'added': 0, 'errorCode': code}
                outcome.update(getattr(error, 'findings', {}))
            except Exception as error:
                # Persist only bounded diagnostic codes, never URLs with secrets,
                # upstream bodies, credentials or exception messages.
                code = 'recovery_identity_changed' if str(error) == 'recovery_identity_changed' else 'recovery_worker_error'
                retry = now + min(86400, 1800 * 2 ** min(job['attempts'] - 1, 6))
                outcome = {'state': 'deferred', 'added': 0, 'errorCode': code}
            outcome['nextRetryAt'] = retry
            with task_db(directory) as conn:
                schema(conn)
                conn.execute('UPDATE jobs SET state=?,result=?,updated=?,next_attempt=?,error_code=? WHERE id=?',
                    ('queued' if retry else 'done', json.dumps([outcome], ensure_ascii=False),
                     now, retry or 0, code, job['id']))
                conn.execute('INSERT INTO route_recovery_audit(job_id,checked_at,event,evidence) VALUES(?,?,?,?)',
                    (job['id'], now, outcome['state'], json.dumps(outcome, ensure_ascii=False)))
            completed.append({'id': job['id'], **outcome})
        try:
            previous = json.loads((directory / 'route-recovery-status.json').read_text())
        except (OSError, ValueError):
            previous = {}
        state = {'time': now, 'execution': 'server', 'processed': len(completed), 'jobs': completed,
                 'lastProcessedAt': now if completed else previous.get('lastProcessedAt'),
                 'lastJobs': completed or previous.get('lastJobs', [])}
        _atomic_write(directory / 'route-recovery-status.json', json.dumps(state, ensure_ascii=False).encode())
        return state


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--limit', type=int, default=1)
    print(json.dumps(run(limit=parser.parse_args().limit), ensure_ascii=False))
