"""Permission-gated programme storage and two-node verified atomic publication.

No grants or mappings are installed implicitly. Existing diagnostic sources
remain unapproved. Fixture publication tests never write to production data.
"""
from datetime import datetime, timezone
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import time

from epg_discovery import fingerprint
from epg_ingest import EpgError, parse_xmltv, fetch
from publish_channel_catalog import _atomic_write
from source_registry import validate_public_url

NODES = ('https://bobtv.briconbric.com', 'https://cndrp.com/bobtv')


def migrate(conn):
    conn.executescript('''
      CREATE TABLE IF NOT EXISTS epg_data_grants (
        source_id TEXT PRIMARY KEY, source_url TEXT NOT NULL,
        evidence_url TEXT NOT NULL, data_license TEXT NOT NULL,
        approved_at INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS epg_data_attributions (
        source_id TEXT PRIMARY KEY, metadata TEXT NOT NULL,
        approved_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS epg_mapping_approvals (
        channel_id TEXT PRIMARY KEY, catalog_identity_hash TEXT NOT NULL,
        source_id TEXT NOT NULL, original_id TEXT NOT NULL,
        source_identity_hash TEXT NOT NULL, confidence REAL NOT NULL,
        evidence TEXT NOT NULL, approved_at INTEGER NOT NULL,
        locked INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS epg_programmes (
        channel_id TEXT NOT NULL, source_id TEXT NOT NULL, original_id TEXT NOT NULL,
        starts INTEGER NOT NULL, stops INTEGER NOT NULL, title TEXT NOT NULL,
        provenance TEXT NOT NULL,
        PRIMARY KEY(channel_id,source_id,original_id,starts,stops,title));
      CREATE TABLE IF NOT EXISTS epg_schedule_state (
        channel_id TEXT PRIMARY KEY, content_hash TEXT,
        last_success INTEGER, last_checked INTEGER, last_failure INTEGER,
        last_error TEXT, coverage_start INTEGER, coverage_end INTEGER);
      CREATE TABLE IF NOT EXISTS epg_programme_audit (
        id INTEGER PRIMARY KEY, channel_id TEXT NOT NULL, checked_at INTEGER NOT NULL,
        state TEXT NOT NULL, content_hash TEXT, reason TEXT);
      CREATE TABLE IF NOT EXISTS epg_publication_audit (
        id INTEGER PRIMARY KEY, checked_at INTEGER NOT NULL,
        version TEXT NOT NULL, sha256 TEXT NOT NULL, node_evidence TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS epg_source_payloads (
        source_id TEXT PRIMARY KEY, sha256 TEXT NOT NULL, fetched_at INTEGER NOT NULL,
        cached_at INTEGER NOT NULL, file_name TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS epg_ingestion_jobs (
        channel_id TEXT PRIMARY KEY, input_hash TEXT NOT NULL, state TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0, next_retry INTEGER NOT NULL DEFAULT 0,
        checked_at INTEGER NOT NULL, last_error TEXT);
      CREATE TABLE IF NOT EXISTS epg_publication_manifests (
        audit_id INTEGER PRIMARY KEY, manifest TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS epg_publication_state (
        id INTEGER PRIMARY KEY CHECK(id=1), audit_id INTEGER NOT NULL);
    ''')


def _validate_data_attribution(configuration, data_license, attribution):
    if configuration.get('format') == 'tvmaze-json' and data_license != 'CC BY-SA 4.0':
        raise EpgError('tvmaze_data_license_mismatch')
    if data_license == 'CC BY-SA 4.0':
        required = {'sourceLabel', 'attributionUrl', 'licenseUrl', 'modificationNotice', 'shareAlikeRequired'}
        if (not isinstance(attribution, dict) or set(attribution) != required
                or attribution['shareAlikeRequired'] is not True
                or attribution['licenseUrl'] != 'https://creativecommons.org/licenses/by-sa/4.0/'
                or any(not isinstance(attribution[key], str) or not 1 <= len(attribution[key].strip()) <= 512
                    for key in ('sourceLabel', 'modificationNotice'))):
            raise EpgError('source_attribution_required')
        validate_public_url(attribution['attributionUrl'])
        if configuration.get('format') == 'tvmaze-json' and (attribution['sourceLabel'] != 'TVmaze'
                or attribution['attributionUrl'] != 'https://www.tvmaze.com/'):
            raise EpgError('tvmaze_attribution_mismatch')
    elif attribution is not None:
        raise EpgError('unsupported_attribution_license')


def reviewed_data_use(conn, source_id):
    """Read-only current data-rights evidence, never a channel mapping approval."""
    tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if not {'epg_data_grants', 'epg_data_attributions'} <= tables:
        return None
    row = conn.execute('''SELECT g.*,h.url,h.configuration,a.metadata FROM epg_data_grants g
      JOIN source_health h ON h.id=g.source_id
      LEFT JOIN epg_data_attributions a ON a.source_id=g.source_id
      WHERE g.source_id=? AND g.revoked=0''', (source_id,)).fetchone()
    if not row or row['source_url'] != row['url']:
        return None
    try:
        if not isinstance(row['data_license'], str) or not row['data_license'].strip():
            return None
        validate_public_url(row['source_url'])
        validate_public_url(row['evidence_url'])
        configuration = json.loads(row['configuration'])
        attribution = json.loads(row['metadata']) if row['metadata'] is not None else None
        if not isinstance(configuration, dict):
            return None
        _validate_data_attribution(configuration, row['data_license'], attribution)
    except (EpgError, ValueError, TypeError, KeyError):
        return None
    return {'dataLicense': row['data_license'], 'dataLicenseEvidenceUrl': row['evidence_url'],
        'reviewFingerprint': fingerprint([row['source_url'], row['evidence_url'],
            row['data_license'], row['approved_at'], attribution])}


def approve_data_use(conn, source_id, *, source_url, evidence_url, data_license,
                     programme_data_permission=False, attribution=None, now=None):
    """Trusted administrator entry point; a code license alone is insufficient."""
    if programme_data_permission is not True or not isinstance(data_license, str) or not data_license.strip():
        raise EpgError('programme_data_permission_required')
    validate_public_url(source_url)
    validate_public_url(evidence_url)
    row = conn.execute('SELECT url,configuration FROM source_health WHERE id=?', (source_id,)).fetchone()
    if not row or row['url'] != source_url:
        raise EpgError('source_url_mismatch')
    _validate_data_attribution(json.loads(row['configuration']), data_license, attribution)
    approved_at = int(time.time() if now is None else now)
    with conn:
        conn.execute('INSERT OR REPLACE INTO epg_data_grants VALUES(?,?,?,?,?,0)',
            (source_id, source_url, evidence_url, data_license, approved_at))
        conn.execute('DELETE FROM epg_data_attributions WHERE source_id=?', (source_id,))
        if attribution:
            conn.execute('INSERT INTO epg_data_attributions VALUES(?,?,?)',
                (source_id, json.dumps(attribution, sort_keys=True), approved_at))


def _source_context(row):
    try:
        context = json.loads(row['context_json'] or '{}')
    except (TypeError, ValueError):
        raise EpgError('invalid_source_identity_context') from None
    if not isinstance(context, dict):
        raise EpgError('invalid_source_identity_context')
    return context


def source_identity(row):
    identity = [row['original_id'], json.loads(row['names_json'])]
    context = _source_context(row)
    # Preserve existing XML identity hashes when there is no structured context.
    # A network, country, region or timezone change invalidates a prior review.
    return fingerprint(identity + ([context] if context else []))


def approve_mapping(conn, channel_id, source_id, original_id, *, evidence,
                    confidence=1.0, locked=True, now=None):
    """Explicit context review, with immutable identity fingerprints and locks."""
    job = conn.execute('SELECT * FROM discovery_jobs WHERE channel_id=? AND active=1', (channel_id,)).fetchone()
    source = conn.execute('''SELECT i.*,c.context_json FROM source_identities i
      LEFT JOIN source_identity_context c ON c.source_id=i.source_id AND c.original_id=i.original_id
      WHERE i.source_id=? AND i.original_id=?''',
        (source_id, original_id)).fetchone()
    if not job or not source or not isinstance(evidence, dict):
        raise EpgError('identity_review_required')
    channel = json.loads(job['payload'])
    required = {'evidenceUrl', 'countryCode', 'regionCode', 'sourceCountryCode', 'sourceRegionCode', 'sameChannelAndDelayVersion'}
    if not required <= evidence.keys() or evidence['sameChannelAndDelayVersion'] is not True:
        raise EpgError('identity_context_unverified')
    validate_public_url(evidence['evidenceUrl'])
    if not channel.get('countryCode') or evidence['countryCode'] != channel['countryCode'] or evidence['regionCode'] != channel.get('regionCode'):
        raise EpgError('catalog_context_mismatch')
    if evidence['sourceCountryCode'] != evidence['countryCode'] or evidence['sourceRegionCode'] != evidence['regionCode']:
        raise EpgError('source_context_mismatch')
    context = _source_context(source)
    if ((context.get('countryCode') and context['countryCode'] != evidence['sourceCountryCode'])
            or ('regionCode' in context and context['regionCode'] != evidence['sourceRegionCode'])):
        raise EpgError('source_context_mismatch')
    if type(confidence) not in (int, float) or not 0.95 <= confidence <= 1:
        raise EpgError('identity_confidence_required')
    previous = conn.execute('SELECT * FROM epg_mapping_approvals WHERE channel_id=?', (channel_id,)).fetchone()
    identity_hash = source_identity(source)
    if previous and previous['locked'] and (previous['source_id'], previous['original_id'], previous['catalog_identity_hash'], previous['source_identity_hash']) != (source_id, original_id, job['identity_hash'], identity_hash):
        raise EpgError('mapping_locked')
    with conn:
        conn.execute('INSERT OR REPLACE INTO epg_mapping_approvals VALUES(?,?,?,?,?,?,?,?,?,0)',
            (channel_id, job['identity_hash'], source_id, original_id, identity_hash, confidence,
             json.dumps(evidence, sort_keys=True), int(time.time() if now is None else now), int(locked)))


def _approved(conn, channel_id):
    row = conn.execute('''SELECT a.*,j.identity_hash,j.payload,i.names_json,i.original_id AS checked_original_id,
      g.source_url,g.evidence_url,g.data_license,c.context_json FROM epg_mapping_approvals a
      JOIN discovery_jobs j ON j.channel_id=a.channel_id AND j.active=1
      JOIN source_identities i ON i.source_id=a.source_id AND i.original_id=a.original_id
      LEFT JOIN source_identity_context c ON c.source_id=i.source_id AND c.original_id=i.original_id
      JOIN epg_data_grants g ON g.source_id=a.source_id AND g.revoked=0
      WHERE a.channel_id=? AND a.revoked=0''', (channel_id,)).fetchone()
    if not row:
        raise EpgError('approved_mapping_and_data_grant_required')
    if row['catalog_identity_hash'] != row['identity_hash'] or row['source_identity_hash'] != source_identity(row):
        raise EpgError('mapping_identity_drift')
    if row['data_license'] == 'CC BY-SA 4.0' and not conn.execute(
            'SELECT 1 FROM epg_data_attributions WHERE source_id=?', (row['source_id'],)).fetchone():
        raise EpgError('source_attribution_required')
    # An existing approval row is insufficient after source URL, licence,
    # permission evidence or attribution has changed or become invalid.
    # Reuse the same current-rights validator as discovery and coverage before
    # any raw cache handoff, programme ingestion or new public snapshot.
    if reviewed_data_use(conn, row['source_id']) is None:
        raise EpgError('current_data_use_review_required')
    return row


def ingest_batch(conn, source_id, payload, channel_ids, *, fetched_at, now=None):
    """At most five approved public identities; last valid schedules survive failure."""
    now = int(time.time() if now is None else now)
    if not 1 <= len(channel_ids) <= 5 or len(set(channel_ids)) != len(channel_ids):
        raise EpgError('batch_size_limit')
    approved = [_approved(conn, identity) for identity in channel_ids]
    if any(row['source_id'] != source_id for row in approved):
        raise EpgError('source_mapping_mismatch')
    source = conn.execute('SELECT * FROM source_health WHERE id=?', (source_id,)).fetchone()
    digest = hashlib.sha256(payload).hexdigest()
    if not source or digest != source['content_sha256'] or fetched_at != source['last_success'] or fetched_at > now + 60:
        raise EpgError('fetch_provenance_mismatch')
    from epg_ingest import parse_source
    parsed = parse_source(json.loads(source['configuration']), payload, now)
    fetch_receipt = json.loads(source['response_metadata'] or '{}') or {}
    result = []
    for mapping in approved:
        identity, original_id = mapping['channel_id'], mapping['original_id']
        programmes = [p for p in parsed['programmes'] if p['originalChannelId'] == original_id]
        has_now = any(p['startUtc'] <= now < p['endUtc'] for p in programmes)
        has_next = any(p['startUtc'] > now for p in programmes)
        if not has_now or not has_next:
            with conn:
                conn.execute('''INSERT INTO epg_schedule_state(channel_id,last_checked,last_failure,last_error)
                  VALUES(?,?,?,?) ON CONFLICT(channel_id) DO UPDATE SET last_checked=excluded.last_checked,
                  last_failure=excluded.last_failure,last_error=excluded.last_error''',
                    (identity, now, now, 'insufficient_current_future_coverage'))
                conn.execute('INSERT INTO epg_programme_audit(channel_id,checked_at,state,reason) VALUES(?,?,?,?)',
                    (identity, now, 'retained_last_good', 'insufficient_current_future_coverage'))
            result.append({'channelId': identity, 'changed': False, 'retainedLastGood': True})
            continue
        semantic_hash = fingerprint([mapping['source_id'], original_id, mapping['catalog_identity_hash'],
            mapping['source_identity_hash'], mapping['data_license'], mapping['evidence_url'],
            mapping['evidence'], mapping['confidence'], programmes])
        with conn:
            conn.execute('BEGIN IMMEDIATE')
            _approved(conn, identity)
            fresh = conn.execute('SELECT content_sha256,last_success FROM source_health WHERE id=?', (source_id,)).fetchone()
            if fresh['content_sha256'] != digest or fresh['last_success'] != fetched_at:
                raise EpgError('fetch_changed_during_ingestion')
            old = conn.execute('SELECT content_hash FROM epg_schedule_state WHERE channel_id=?', (identity,)).fetchone()
            changed = not old or old['content_hash'] != semantic_hash
            if changed:
                conn.execute('DELETE FROM epg_programmes WHERE channel_id=?', (identity,))
                for programme in programmes:
                    provenance = {**programme, 'sourceUrl': mapping['source_url'], 'fetchedAtUtc': fetched_at,
                        'programmeSourceUrl': programme.get('sourceUrl', mapping['source_url']),
                        'fetchedSourceUrl': fetch_receipt.get('sourceUrl', mapping['source_url']),
                        'rawSha256': digest, 'dataLicenseEvidenceUrl': mapping['evidence_url'],
                        'dataLicense': mapping['data_license'],
                        'mappingEvidence': json.loads(mapping['evidence']), 'confidence': mapping['confidence'],
                        'originalChannelNames': parsed['channels'][original_id]}
                    conn.execute('INSERT INTO epg_programmes VALUES(?,?,?,?,?,?,?)',
                        (identity, source_id, original_id, programme['startUtc'], programme['endUtc'],
                         programme['title'], json.dumps(provenance, ensure_ascii=False, sort_keys=True)))
            conn.execute('''INSERT INTO epg_schedule_state VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(channel_id)
              DO UPDATE SET content_hash=excluded.content_hash,last_success=excluded.last_success,
              last_checked=excluded.last_checked,last_error=NULL,coverage_start=excluded.coverage_start,
              coverage_end=excluded.coverage_end''',
                (identity, semantic_hash, now, now, None, None,
                 min(p['startUtc'] for p in programmes), max(p['endUtc'] for p in programmes)))
            conn.execute('INSERT INTO epg_programme_audit(channel_id,checked_at,state,content_hash) VALUES(?,?,?,?)',
                (identity, now, 'changed' if changed else 'unchanged', semantic_hash))
        result.append({'channelId': identity, 'changed': changed, 'retainedLastGood': False})
    return result


def approval_fingerprint(conn):
    return fingerprint({table: [list(row) for row in conn.execute('SELECT * FROM ' + table + ' ORDER BY 1')]
        for table in ('epg_data_grants', 'epg_mapping_approvals', 'epg_data_attributions')})


def cache_validated_payload(conn, directory, source_id, payload, now):
    """Private handoff only after data rights AND a current exact mapping grant.

    The validator owns worker.lock during this operation. Unapproved diagnostic
    feeds never acquire a raw programme cache. One bounded file per source is
    atomically replaced, independently of the last-good programme database.
    """
    if not conn.execute("SELECT 1 FROM sqlite_master WHERE name='epg_data_grants'").fetchone():
        return False
    if not conn.execute('SELECT 1 FROM epg_data_grants WHERE source_id=? AND revoked=0', (source_id,)).fetchone():
        return False
    permitted = False
    for row in conn.execute('SELECT channel_id FROM epg_mapping_approvals WHERE source_id=? AND revoked=0', (source_id,)).fetchall():
        try:
            _approved(conn, row['channel_id'])
            permitted = True
            break
        except EpgError:
            continue
    if not permitted:
        return False
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,79}', source_id) or not 0 < len(payload) <= 8 * 1024 * 1024:
        raise EpgError('payload_cache_limit')
    digest = hashlib.sha256(payload).hexdigest()
    receipt = conn.execute('SELECT content_sha256,last_success FROM source_health WHERE id=?', (source_id,)).fetchone()
    if not receipt or receipt['content_sha256'] != digest or receipt['last_success'] != now:
        raise EpgError('fetch_provenance_mismatch')
    migrate(conn)
    path = Path(directory) / 'payload-cache' / (source_id + '.bin')
    if path.is_symlink() or path.parent.is_symlink():
        raise EpgError('unsafe_payload_cache_path')
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    _atomic_write(path, payload)
    os.chmod(path, 0o600)
    with conn:
        conn.execute('INSERT OR REPLACE INTO epg_source_payloads VALUES(?,?,?,?,?)',
            (source_id, digest, now, now, path.name))
    return True


def build_payload(conn, now=None):
    now = int(time.time() if now is None else now)
    channels, programmes = [], []
    for (identity,) in conn.execute('SELECT channel_id FROM epg_mapping_approvals ORDER BY channel_id').fetchall():
        try:
            mapping = _approved(conn, identity)
        except EpgError:
            continue
        rows = conn.execute('''SELECT * FROM epg_programmes WHERE channel_id=? AND source_id=? AND original_id=?
          AND stops>? AND starts<=? ORDER BY starts,stops,title''',
            (identity, mapping['source_id'], mapping['original_id'], now - 2 * 86400, now + 14 * 86400)).fetchall()
        # A grant or contextual review can change before the next ingestion.
        # Retain the last-good rows privately until their provenance is rebuilt
        # under the current approval, and never publish a mixed permission set.
        expected_provenance = {
            'sourceUrl': mapping['source_url'],
            'dataLicense': mapping['data_license'],
            'dataLicenseEvidenceUrl': mapping['evidence_url'],
            'mappingEvidence': json.loads(mapping['evidence']),
            'confidence': mapping['confidence'],
            'originalChannelNames': json.loads(mapping['names_json']),
        }
        checked_rows = []
        for row in rows:
            try:
                provenance = json.loads(row['provenance'])
            except (TypeError, ValueError):
                break
            if not isinstance(provenance, dict) or any(
                    provenance.get(key) != value for key, value in expected_provenance.items()):
                break
            checked_rows.append((row, provenance))
        if len(checked_rows) != len(rows):
            continue
        if not any(p['starts'] <= now < p['stops'] for p in rows) or not any(p['starts'] > now for p in rows):
            continue
        channel = json.loads(mapping['payload'])
        channels.append({**channel, 'sourceId': mapping['source_id'], 'originalChannelId': mapping['original_id'],
            'catalogIdentityHash': mapping['catalog_identity_hash'], 'confidence': mapping['confidence']})
        for row, provenance in checked_rows:
            programmes.append({'channelId': identity, 'sourceId': row['source_id'], 'originalChannelId': row['original_id'],
                'title': row['title'], 'startUtc': row['starts'], 'stopUtc': row['stops'],
                'provenance': provenance})
    if not channels or not programmes:
        raise EpgError('no_publishable_current_future_data')
    if len(channels) > 10000 or len(programmes) > 200000:
        raise EpgError('publication_size_limit')
    sources = {c['sourceId'] for c in channels}
    attributions = [{'sourceId': row['source_id'], **json.loads(row['metadata'])}
        for row in conn.execute('SELECT * FROM epg_data_attributions ORDER BY source_id') if row['source_id'] in sources]
    core = {'schemaVersion': 1, 'channels': channels, 'programmes': programmes,
        'dataAttributions': attributions}
    return {**core, 'version': 'epg-' + fingerprint(core)}


def _node_fetch(url):
    return fetch({'url': url})[0]


def active_manifest(conn):
    """The sole public activation pointer, committed with its audit and receipt.

    Legacy mutable filesystem manifests are deliberately never consulted.
    Missing migrations mean no new publication; broken links fail closed.
    """
    if not conn.execute("SELECT 1 FROM sqlite_master WHERE name='epg_publication_state'").fetchone():
        return None
    state = conn.execute('SELECT audit_id FROM epg_publication_state WHERE id=1').fetchone()
    if state is None:
        return None
    row = conn.execute('''SELECT m.manifest,a.version,a.sha256 FROM epg_publication_manifests m
      JOIN epg_publication_audit a ON a.id=m.audit_id WHERE m.audit_id=?''', (state[0],)).fetchone()
    if not row or not isinstance(row[0], str) or len(row[0]) > 65536:
        raise EpgError('invalid_publication_receipt')
    try:
        manifest = json.loads(row[0])
        if (not isinstance(manifest, dict) or manifest.get('schemaVersion') != 1
                or manifest.get('version') != row[1] or manifest.get('sha256') != row[2]
                or not re.fullmatch(r'epg-[a-f0-9]{64}', manifest['version'])
                or not re.fullmatch(r'[a-f0-9]{64}', manifest['sha256'])
                or manifest.get('snapshotUrl') != '/api/v1/epg/snapshots/' + manifest['sha256'] + '.json.gz'
                or any(type(manifest.get(key)) is not int or not low <= manifest[key] <= high
                    for key,low,high in (('compressedBytes',1,8*1024*1024),('channelCount',1,10000),
                        ('programmeCount',1,200000),('coverageStartUtc',0,4102444800),('coverageEndUtc',0,4102444800)))
                or manifest['coverageEndUtc'] <= manifest['coverageStartUtc']
                or not isinstance(manifest.get('generatedAt'),str) or not manifest['generatedAt'].endswith('Z')):
            raise ValueError('invalid receipt')
        datetime.fromisoformat(manifest['generatedAt'].replace('Z','+00:00'))
    except (ValueError, TypeError, KeyError):
        raise EpgError('invalid_publication_receipt') from None
    return manifest


def _publication_revision(conn):
    # data_version observes commits from other connections; total_changes
    # covers writes through this connection. Compare on this connection only.
    return conn.execute('PRAGMA main.data_version').fetchone()[0], conn.total_changes


def _coverage_deadline(payload, now):
    """Conservative deadline while every included channel is current + future.

    Compute outside the activation transaction. Crossing a programme boundary
    triggers a fresh preflight, even if another current programme could take over.
    """
    coverage = {channel['id']: [0, 0] for channel in payload['channels']}
    for programme in payload['programmes']:
        current_stop, future_start = coverage[programme['channelId']]
        if programme['startUtc'] <= now < programme['stopUtc']:
            current_stop = max(current_stop, programme['stopUtc'])
        if programme['startUtc'] > now:
            future_start = max(future_start, programme['startUtc'])
        coverage[programme['channelId']] = current_stop, future_start
    deadline = min(min(bounds) for bounds in coverage.values())
    if deadline <= now:
        raise EpgError('no_publishable_current_future_data')
    return deadline


def publish(conn, directory, *, now=None, node_fetcher=_node_fetch):
    """Snapshot first, node proofs next, DB audit and visible pointer together."""
    live_clock = now is None
    now = int(time.time() if now is None else now)
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / 'publish.lock').open('a') as lock:
        import fcntl
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        approval_state = approval_fingerprint(conn)
        payload = build_payload(conn, now)
        raw = json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()
        if len(raw) > 32 * 1024 * 1024:
            raise EpgError('publication_decoded_limit')
        compressed = gzip.compress(raw, mtime=0)
        if len(compressed) > 8 * 1024 * 1024:
            raise EpgError('publication_compressed_limit')
        digest = hashlib.sha256(compressed).hexdigest()
        previous = active_manifest(conn)
        if previous is not None and previous['sha256'] == digest:
            return {**previous, 'changed': False}
        snapshot = directory / 'snapshots' / (digest + '.json.gz')
        if not snapshot.exists() or hashlib.sha256(snapshot.read_bytes()).hexdigest() != digest:
            _atomic_write(snapshot, compressed)
        snapshot_url = '/api/v1/epg/snapshots/' + digest + '.json.gz'
        proofs = []
        for node in NODES:
            try:
                downloaded = node_fetcher(node + snapshot_url)
            except (OSError, ValueError):
                raise EpgError('public_snapshot_unavailable') from None
            if len(downloaded) != len(compressed) or hashlib.sha256(downloaded).hexdigest() != digest:
                raise EpgError('public_snapshot_checksum_mismatch')
            if json.loads(gzip.decompress(downloaded)) != payload:
                raise EpgError('public_snapshot_content_mismatch')
            proofs.append({'node': node, 'sha256': digest, 'programmeCount': len(payload['programmes'])})
        manifest = {'schemaVersion': 1, 'version': payload['version'], 'sha256': digest,
            'snapshotUrl': snapshot_url, 'compressedBytes': len(compressed),
            'channelCount': len(payload['channels']), 'programmeCount': len(payload['programmes']),
            'generatedAt': datetime.fromtimestamp(now, timezone.utc).isoformat().replace('+00:00', 'Z'),
            'coverageStartUtc': min(p['startUtc'] for p in payload['programmes']),
            'coverageEndUtc': max(p['stopUtc'] for p in payload['programmes'])}
        # Full identity, permission, provenance and programme scans stay outside
        # the write transaction. Any intervening database write fails closed.
        revision = _publication_revision(conn)
        preflight_now = int(time.time()) if live_clock else now
        if approval_state != approval_fingerprint(conn):
            raise EpgError('approval_changed_during_publication')
        if build_payload(conn, preflight_now)['version'] != payload['version']:
            raise EpgError('data_changed_during_publication')
        coverage_deadline = _coverage_deadline(payload, preflight_now)
        with conn:
            conn.execute('BEGIN IMMEDIATE')
            activation_now = int(time.time()) if live_clock else now
            if revision != _publication_revision(conn) or activation_now < preflight_now:
                raise EpgError('data_changed_during_publication')
            if activation_now >= coverage_deadline:
                raise EpgError('no_publishable_current_future_data')
            manifest['generatedAt'] = datetime.fromtimestamp(activation_now, timezone.utc).isoformat().replace('+00:00', 'Z')
            audit = conn.execute('INSERT INTO epg_publication_audit(checked_at,version,sha256,node_evidence) VALUES(?,?,?,?)',
                (activation_now, payload['version'], digest, json.dumps(proofs)))
            conn.execute('INSERT INTO epg_publication_manifests VALUES(?,?)',
                (audit.lastrowid, json.dumps(manifest, separators=(',', ':'))))
            conn.execute('INSERT INTO epg_publication_state VALUES(1,?) ON CONFLICT(id) DO UPDATE SET audit_id=excluded.audit_id',
                (audit.lastrowid,))
        return {**manifest, 'changed': True}
