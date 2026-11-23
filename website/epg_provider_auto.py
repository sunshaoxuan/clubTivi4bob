"""Autonomous EPG admission from publisher-owned service identifiers.

Delivery URLs are used only to bind an existing public channel to a publisher's
stable service ID. This worker neither adds playback URLs nor authorizes playback.
"""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import time
from urllib.parse import parse_qsl, urlsplit

from catalog_inventory import DATA
import epg_discovery as discovery
from epg_ingest import database, EpgError, fetch_source, parse_source, probe_batch, registry
import epg_store as store
from epg_pluto import route_id, API as PLUTO_API

POLICY = 'publisher_provider_id_v1'


def target_hash(channel, selected):
    identity = {k: channel.get(k) for k in ('id', 'name', 'countryCode', 'regionCode', 'epgId')}
    identity['routes'] = sorted((r['id'], r['url']) for r in channel['routes'])
    return discovery.fingerprint([identity, selected])


def selection(channel):
    routes = channel.get('routes', [])
    country = channel.get('countryCode')
    if not routes or not isinstance(country, str) or not re.fullmatch(r'[A-Z]{2}', country):
        return None
    identities = []
    for route in routes:
        url = route['url']
        p = urlsplit(url)
        if any(re.search(r'start|stop|offset|timeshift|delay|dvr', k, re.I)
               for k, _ in parse_qsl(p.query)):
            return None
        identity = route_id(url)
        if identity:
            identities.append(('pluto', identity))
            continue
        match = re.search(r'/production-(?:LiveChannel-(\d+)|hls-aes128-rtv-(\d+)-playout)/', p.path)
        if p.scheme == 'https' and (p.hostname or '').endswith('.fast.rakuten.tv') and match:
            identities.append(('rakuten', int(match[1] or match[2])))
        else:
            return None
    return identities[0] if len(set(identities)) == 1 else None


def source_for(channel, selected, sources):
    kind, identity = selected
    if kind == 'pluto':
        return {'id': 'pluto-auto-'+channel['countryCode'].lower()+'-'+identity, 'url': PLUTO_API, 'format': 'pluto-json',
            'serviceId': identity, 'countryCode': channel['countryCode'],
            'countryBasis': 'catalogue_presentation', 'calendarTimezone': 'UTC',
            'redirectUrls': [], 'refreshSeconds': 900, 'minimumRetrySeconds': 900,
            'publicationAllowed': False,
            'dataLicense': {'status': 'operator_authorized_factual_schedule_scope',
                'evidenceUrl': PLUTO_API+'/'+identity,
                'restriction': 'Operator requested automatic factual EPG integration. Exact global provider ID; '
                    'country is catalogue presentation metadata. Only titles, times and event IDs are retained.'}}
    matches = [s for s in sources if s.get('format') == 'rakuten-json'
               and s.get('countryCode') == channel['countryCode']]
    return matches[0] if len(matches) == 1 else None


def migrate(conn):
    conn.execute('''CREATE TABLE IF NOT EXISTS epg_provider_auto_jobs(
      channel_id TEXT PRIMARY KEY,input_hash TEXT NOT NULL,state TEXT NOT NULL,
      next_retry INTEGER NOT NULL,updated_at INTEGER NOT NULL,last_error TEXT,source_id TEXT)''')
    conn.commit()


def run(root=DATA, *, now=None, batch_size=3):
    now = int(time.time()) if now is None else now
    if not 1 <= batch_size <= 5:
        raise EpgError('batch_size_limit')
    root = Path(root); directory = root/'epg'
    directory.mkdir(parents=True, exist_ok=True)
    result = {'stage': 'publisher_provider_discovery', 'checkedAtUtc': now,
              'examined': 0, 'newMappings': 0, 'mapped': [], 'deferred': [], 'upstreamRequests': 0}
    with (directory/'provider-auto.lock').open('a') as owner:
        try:
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {**result, 'state': 'already_running'}
        _, channels = discovery.load_catalog(root)
        sources = registry()
        conn = database(directory); discovery.migrate(conn); store.migrate(conn); migrate(conn)
        from epg_channel_research import migrate as migrate_research
        migrate_research(conn)
        candidates = []
        for channel in channels:
            selected = selection(channel)
            if not selected:
                continue
            old = conn.execute('SELECT * FROM epg_mapping_approvals WHERE channel_id=?', (channel['id'],)).fetchone()
            if old and (old['revoked'] or old['locked'] or json.loads(old['evidence']).get('automaticAdmission') != POLICY):
                continue
            digest = target_hash(channel, selected)
            job = conn.execute('SELECT * FROM epg_provider_auto_jobs WHERE channel_id=?', (channel['id'],)).fetchone()
            if job and job['input_hash'] == digest and job['next_retry'] > now:
                continue
            source = source_for(channel, selected, sources)
            if source:
                candidates.append((bool(old), job['updated_at'] if job else 0, channel, selected, source, digest))
        candidates.sort(key=lambda x: (x[0], x[1], x[2]['id']))
        # Network and DB work is serialized with the normal validator. Other
        # workers and the read-only API keep their own independent schedules.
        with (directory/'worker.lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                conn.close(); return {**result, 'state': 'validator_busy'}
            manifest, fresh = discovery.load_catalog(root)
            discovery.sync_catalog(conn, manifest, fresh, now)
            for _, _, channel, selected, source, digest in candidates[:batch_size]:
                result['examined'] += 1
                cid = channel['id']; state, error, retry = 'waiting_source', None, now+900
                try:
                    captured = []
                    health = conn.execute('SELECT * FROM source_health WHERE id=?', (source['id'],)).fetchone()
                    if not health or health['next_retry'] <= now:
                        def fetch_one(s):
                            try:
                                item = fetch_source(s, now)
                            except EpgError as exc:
                                if str(exc) == 'http_404': exc.retry_after = max(exc.retry_after, 86400)
                                raise
                            captured.append(item)
                            return item
                        result['upstreamRequests'] += 1
                        probe_batch(directory, [source], now, fetch_one)
                        health = conn.execute('SELECT * FROM source_health WHERE id=?', (source['id'],)).fetchone()
                    retry = max(now+60, health['next_retry'])
                    if health['last_error'] or not health['last_success']:
                        raise EpgError(health['last_error'] or 'source_not_ready')
                    cached = conn.execute('SELECT * FROM epg_source_payloads WHERE source_id=?', (source['id'],)).fetchone()
                    if captured and health['last_success'] == now:
                        body, _ = captured[0]; fetched_at = now
                    elif cached and cached['fetched_at'] == health['last_success']:
                        body = (directory/'payload-cache'/cached['file_name']).read_bytes()
                        if hashlib.sha256(body).hexdigest() != cached['sha256'] or cached['sha256'] != health['content_sha256']:
                            raise EpgError('payload_cache_checksum_mismatch')
                        fetched_at = cached['fetched_at']
                    else:
                        raise EpgError('waiting_validated_source_payload')
                    parsed = parse_source(source, body, now)
                    matching = [oid for oid, ctx in parsed.get('identityContexts', {}).items()
                        if ((selected[0] == 'pluto' and ctx.get('providerChannelId') == selected[1])
                            or (selected[0] == 'rakuten' and ctx.get('serviceId') == selected[1]))]
                    if len(matching) != 1:
                        raise EpgError('publisher_service_id_not_in_schedule')
                    original = matching[0]; context = parsed['identityContexts'][original]
                    events = [p for p in parsed['programmes'] if p['originalChannelId'] == original]
                    if sum(p['startUtc'] <= now < p['endUtc'] for p in events) != 1 or not any(p['startUtc'] > now for p in events):
                        raise EpgError('insufficient_current_future_coverage')
                    _, current = discovery.load_catalog(root)
                    actual = next((c for c in current if c['id'] == cid), None)
                    if actual is None or target_hash(actual, selection(actual)) != digest:
                        raise EpgError('provider_catalogue_changed')
                    scope = sorted([{'routeId': r['id'], 'urlSha256': hashlib.sha256(r['url'].encode()).hexdigest()}
                                    for r in actual['routes']], key=lambda r: r['routeId'])
                    evidence = {'automaticAdmission': POLICY, 'evidenceUrl': source['dataLicense']['evidenceUrl'],
                        'countryCode': actual['countryCode'], 'regionCode': actual.get('regionCode'),
                        'sourceCountryCode': actual['countryCode'], 'sourceRegionCode': actual.get('regionCode'),
                        'sameChannelAndDelayVersion': True, 'routeScopeExplicitlyReviewed': True, 'routeScope': scope,
                        'publisherServiceId': selected[1], 'publisherNames': parsed['channels'][original],
                        'countryBasis': source.get('countryBasis', 'provider_market'),
                        'providerChannelId': context.get('providerChannelId'),
                        'providerMarketCode': context.get('marketCode'), 'providerServiceId': context.get('serviceId')}
                    if selected[0] == 'rakuten':
                        from epg_rakuten import verify_current_catalogue_route
                        verify_current_catalogue_route(cid, context, evidence)
                    previous = conn.execute('SELECT * FROM epg_mapping_approvals WHERE channel_id=?', (cid,)).fetchone()
                    with conn:
                        conn.execute('BEGIN IMMEDIATE')
                        current_approval = conn.execute('SELECT * FROM epg_mapping_approvals WHERE channel_id=?', (cid,)).fetchone()
                        if ((dict(current_approval) if current_approval else None) != (dict(previous) if previous else None)
                                or current_approval and (current_approval['revoked'] or current_approval['locked']
                                    or json.loads(current_approval['evidence']).get('automaticAdmission') != POLICY)):
                            raise EpgError('provider_mapping_protected')
                        if store.reviewed_data_use(conn, source['id']) is None:
                            if conn.execute('SELECT 1 FROM epg_data_grants WHERE source_id=?', (source['id'],)).fetchone():
                                raise EpgError('provider_source_permission_disabled')
                            store.approve_data_use(conn, source['id'], source_url=source['url'],
                                evidence_url=evidence['evidenceUrl'], programme_data_permission=True,
                                data_license='Operator-authorized publisher schedule facts; titles, times and IDs only',
                                now=now, in_transaction=True)
                        store.approve_mapping(conn, cid, source['id'], original, evidence=evidence,
                                              locked=False, now=now, in_transaction=True)
                    store.cache_validated_payload(conn, directory, source['id'], body, fetched_at)
                    store.ingest_batch(conn, source['id'], body, [cid], fetched_at=fetched_at, now=now)
                    from epg_channel_research import deactivate
                    deactivate(conn, cid, now, 'publisher_provider_mapping_available')
                    state = 'mapped'; result['newMappings'] += int(previous is None); result['mapped'].append(cid)
                except (EpgError, OSError, ValueError, sqlite3.Error) as exc:
                    error = str(exc) if isinstance(exc, EpgError) else 'provider_discovery_unavailable'
                    result['deferred'].append({'channelId': cid, 'reason': error, 'nextRetryAtUtc': retry})
                with conn:
                    conn.execute('INSERT OR REPLACE INTO epg_provider_auto_jobs VALUES(?,?,?,?,?,?,?)',
                        (cid, digest, state, retry, now, error, source['id']))
        with conn:
            conn.execute('INSERT OR REPLACE INTO epg_checkpoints VALUES(?,?)', ('provider_auto', json.dumps(result)))
        conn.close()
    return {**result, 'state': 'processed' if result['examined'] else 'idle'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir', type=Path, default=DATA)
    parser.add_argument('--batch-size', type=int, default=3)
    args = parser.parse_args()
    print(json.dumps(run(args.data_dir, batch_size=args.batch_size), ensure_ascii=False))
