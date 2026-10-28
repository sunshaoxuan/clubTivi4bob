"""Bounded per-channel monitoring of already approved programme mappings.

Runs independently of payload changes. Keeps a durable, idempotent review queue
without fetching, approving replacements, changing mappings or inventing slots.
The existing schedule timer provides execution, including while the Mac is off.
"""
from collections import Counter
import json

from epg_ingest import EpgError, parse_source
import epg_store as store


def migrate(conn):
    conn.executescript('''
      CREATE TABLE IF NOT EXISTS epg_coverage_gap_jobs (
        channel_id TEXT PRIMARY KEY, identity_hash TEXT NOT NULL,
        source_id TEXT NOT NULL, original_id TEXT NOT NULL,
        state TEXT NOT NULL, reason TEXT NOT NULL, first_seen INTEGER NOT NULL,
        last_checked INTEGER NOT NULL, next_review INTEGER NOT NULL,
        evidence_hash TEXT NOT NULL, evidence TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS epg_coverage_gap_audit (
        id INTEGER PRIMARY KEY, channel_id TEXT NOT NULL, checked_at INTEGER NOT NULL,
        state TEXT NOT NULL, evidence_hash TEXT NOT NULL, evidence TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS epg_coverage_gap_due
        ON epg_coverage_gap_jobs(next_review,last_checked);
    ''')


def _coverage(conn, mapping, now):
    rows = conn.execute('''SELECT starts,stops,provenance FROM epg_programmes
      WHERE channel_id=? AND source_id=? AND original_id=? AND stops>?
      AND starts<=? ORDER BY starts,stops LIMIT 10001''',
        (mapping['channel_id'], mapping['source_id'], mapping['original_id'],
         now, now + 14 * 86400)).fetchall()
    if len(rows) > 10000:
        raise EpgError('channel_monitor_record_limit')
    expected = {'sourceUrl': mapping['source_url'], 'dataLicense': mapping['data_license'],
        'dataLicenseEvidenceUrl': mapping['evidence_url'],
        'mappingEvidence': json.loads(mapping['evidence']), 'confidence': mapping['confidence'],
        'originalChannelNames': json.loads(mapping['names_json'])}
    if any(any(json.loads(row['provenance']).get(k) != v for k, v in expected.items()) for row in rows):
        raise EpgError('channel_monitor_provenance_mismatch')
    if any(a['stops'] > b['starts'] for a, b in zip(rows, rows[1:])):
        raise EpgError('channel_monitor_overlapping_records')
    current = any(row['starts'] <= now < row['stops'] for row in rows)
    future = any(row['starts'] > now for row in rows)
    return current, future, min((row['starts'] for row in rows if row['starts'] > now), default=None)


def run(conn, directory, now, read_payload, limit=5):
    if type(limit) is not int or not 1 <= limit <= 5:
        raise EpgError('coverage_monitor_batch_size_limit')
    migrate(conn)
    selected = conn.execute('''SELECT targets.channel_id FROM (
        SELECT a.channel_id FROM epg_mapping_approvals a
          JOIN discovery_jobs j ON j.channel_id=a.channel_id AND j.active=1 WHERE a.revoked=0
        UNION SELECT channel_id FROM epg_coverage_gap_jobs) targets
      LEFT JOIN discovery_jobs j ON j.channel_id=targets.channel_id
      LEFT JOIN epg_coverage_gap_jobs g ON g.channel_id=targets.channel_id
      WHERE g.channel_id IS NULL OR g.next_review<=?
      ORDER BY COALESCE(g.last_checked,0),COALESCE(j.priority,100),targets.channel_id LIMIT ?''', (now, limit)).fetchall()
    parsed_sources, checked, changed = {}, 0, 0
    for selected_row in selected:
        identity = selected_row['channel_id']
        previous = conn.execute('SELECT * FROM epg_coverage_gap_jobs WHERE channel_id=?', (identity,)).fetchone()
        try:
            mapping = store._approved(conn, identity)
        except EpgError:
            # Retain the original case as history after revocation/context drift.
            if previous:
                evidence = {'channelId': identity, 'catalogIdentityHash': previous['identity_hash'],
                    'sourceId': previous['source_id'], 'originalChannelId': previous['original_id'],
                    'identityAndDataGrantVerified': False, 'reason': 'mapping_or_data_grant_changed',
                    'upstreamRequests': 0, 'newMappings': 0, 'newGrants': 0, 'programmesChanged': False}
                encoded = json.dumps(evidence, ensure_ascii=False, sort_keys=True)
                digest = store.fingerprint(evidence)
                with conn:
                    if previous['evidence_hash'] != digest or previous['state'] != 'approval_requires_review':
                        conn.execute('INSERT INTO epg_coverage_gap_audit(channel_id,checked_at,state,evidence_hash,evidence) VALUES(?,?,?,?,?)',
                            (identity, now, 'approval_requires_review', digest, encoded))
                        changed += 1
                    conn.execute('UPDATE epg_coverage_gap_jobs SET state=?,reason=?,last_checked=?,next_review=?,evidence_hash=?,evidence=? WHERE channel_id=?',
                        ('approval_requires_review', 'mapping_or_data_grant_changed', now, now + 300, digest, encoded, identity))
            continue
        checked += 1
        source = conn.execute('SELECT * FROM source_health WHERE id=?', (mapping['source_id'],)).fetchone()
        current, future, next_start = False, False, None
        conflicts, cache_error = [], None
        try:
            current, future, next_start = _coverage(conn, mapping, now)
            if not current and source and json.loads(source['configuration']).get('format') == 'taipei-monthly-csv':
                # Reuse the single existing licensed cache for both approved
                # channels. No extra upstream request or generic full reparse.
                sid = mapping['source_id']
                if sid not in parsed_sources:
                    cached = conn.execute('SELECT * FROM epg_source_payloads WHERE source_id=?', (sid,)).fetchone()
                    if not cached:
                        raise EpgError('payload_cache_unavailable')
                    body = read_payload(conn, directory, {'source_id': sid, 'cached': dict(cached)}, now)
                    parsed_sources[sid] = parse_source(json.loads(source['configuration']), body, now)
                conflicts = [p for p in parsed_sources[sid]['quality'].get('currentConflictRecords', [])
                    if p['originalChannelId'] == mapping['original_id']]
        except (EpgError, OSError, ValueError, TypeError, AttributeError, KeyError) as error:
            cache_error = str(error) if isinstance(error, EpgError) else 'coverage_monitor_evidence_invalid'
        reason = ('current_source_slot_conflict' if conflicts else
            'coverage_evidence_requires_review' if cache_error else
            'current_and_future_available' if current and future else
            'current_programme_missing' if future else 'future_programmes_missing' if current else
            'current_and_future_missing')
        state = 'covered' if current and future and not cache_error else 'needs_schedule_review'
        evidence = {'channelId': identity, 'catalogIdentityHash': mapping['catalog_identity_hash'],
            'sourceId': mapping['source_id'], 'originalChannelId': mapping['original_id'],
            'mappingLocked': bool(mapping['locked']), 'identityAndDataGrantVerified': True,
            'hasCurrentProgramme': current, 'hasFutureProgrammes': future, 'nextAcceptedStartUtc': next_start,
            'reason': reason, 'conflictingSourceRecords': conflicts, 'cacheError': cache_error,
            'sourceProbeState': source['state'] if source else None,
            'lastSourceSuccessUtc': source['last_success'] if source else None,
            'nextSourceRetryUtc': source['next_retry'] if source else None,
            'sourceContentSha256': source['content_sha256'] if source else None,
            'offAirConfirmed': False, 'upstreamRequests': 0, 'automaticReplacementSearchImplemented': False,
            'newMappings': 0, 'newGrants': 0, 'programmesChanged': False}
        encoded = json.dumps(evidence, ensure_ascii=False, sort_keys=True)
        digest = store.fingerprint(evidence)
        # Time itself is omitted from the fingerprint. Repeated unchanged checks
        # update the due time without flooding the append-only audit.
        with conn:
            if not previous or previous['evidence_hash'] != digest or previous['state'] != state:
                conn.execute('INSERT INTO epg_coverage_gap_audit(channel_id,checked_at,state,evidence_hash,evidence) VALUES(?,?,?,?,?)',
                    (identity, now, state, digest, encoded))
                changed += 1
            conn.execute('''INSERT INTO epg_coverage_gap_jobs VALUES(?,?,?,?,?,?,?,?,?,?,?)
              ON CONFLICT(channel_id) DO UPDATE SET identity_hash=excluded.identity_hash,
              source_id=excluded.source_id,original_id=excluded.original_id,state=excluded.state,
              reason=excluded.reason,last_checked=excluded.last_checked,next_review=excluded.next_review,
              evidence_hash=excluded.evidence_hash,evidence=excluded.evidence''',
                (identity, mapping['catalog_identity_hash'], mapping['source_id'], mapping['original_id'],
                 state, reason, previous['first_seen'] if previous else now, now, now + 60, digest, encoded))
    return {'checkedChannels': checked, 'batchLimit': limit, 'changedCases': changed,
        'states': dict(Counter(row[0] for row in conn.execute('SELECT state FROM epg_coverage_gap_jobs'))),
        'upstreamRequests': 0, 'automaticReplacementSearchImplemented': False}
