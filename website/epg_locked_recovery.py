"""Narrow research access for expired, operator-locked public EPG mappings.

Recovery shares the existing identity-first search queue, budget, leases and
source checks. It has no authority to replace a mapping, grant data use, write
programmes, delete caches or change an upstream source's retry deadline.
"""
import hashlib
import json
import time

import epg_channel_research as queue
import epg_store as store
from epg_coverage_gaps import _coverage
from epg_ingest import EpgError


def migrate(conn):
    conn.executescript('''
      CREATE TABLE IF NOT EXISTS epg_locked_recovery_jobs (
        channel_id TEXT PRIMARY KEY, identity_hash TEXT NOT NULL,
        mapping_hash TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1,
        active INTEGER NOT NULL DEFAULT 1, state TEXT NOT NULL,
        reason TEXT NOT NULL, updated_at INTEGER NOT NULL);
    ''')


def _tables(conn):
    return {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}


def _mapping(conn, cid, now):
    """Fail closed on stale monitoring, rights/identity drift or restored data."""
    gap = conn.execute('SELECT * FROM epg_coverage_gap_jobs WHERE channel_id=?', (cid,)).fetchone()
    if (not gap or gap['state'] != 'needs_schedule_review'
            or not 0 <= now - gap['last_checked'] <= 3600):
        return None
    mapping = store._approved(conn, cid)
    if (not mapping['locked'] or gap['identity_hash'] != mapping['catalog_identity_hash']
            or gap['source_id'] != mapping['source_id'] or gap['original_id'] != mapping['original_id']):
        return None
    evidence = json.loads(gap['evidence'])
    if evidence.get('offAirConfirmed') or not evidence.get('identityAndDataGrantVerified'):
        return None
    current, future, _ = _coverage(conn, mapping, now)
    if current and future:
        return None
    health = conn.execute('SELECT * FROM source_health WHERE id=?', (mapping['source_id'],)).fetchone()
    # A normal off-air interval with future slots is not an outage. Missing
    # all usable data or sustained failure justifies bounded replacement work.
    if (current or future) and (not health or health['failures'] < 3):
        return None
    return mapping


def research_protected_ids(conn, now=None):
    """Default-deny all approvals except a current, explicitly scoped recovery.

    Other discovery consumers keep their original protected_ids function.
    Only the metadata/review worker opts into this research-only exception.
    """
    now = int(time.time() if now is None else now)
    tables = _tables(conn)
    if 'epg_mapping_approvals' not in tables:
        return set()
    protected = {r[0] for r in conn.execute('SELECT channel_id FROM epg_mapping_approvals WHERE revoked=0')}
    if not {'epg_locked_recovery_jobs', 'epg_coverage_gap_jobs', 'epg_channel_research_jobs'} <= tables:
        return protected
    protected.update(r[0] for r in conn.execute('SELECT channel_id FROM epg_locked_recovery_jobs WHERE active=1'))
    for row in conn.execute('''SELECT r.* FROM epg_locked_recovery_jobs r
      JOIN epg_channel_research_jobs j ON j.channel_id=r.channel_id AND j.identity_hash=r.identity_hash
      WHERE r.active=1 AND r.enabled=1 AND j.active=1'''):
        if row['channel_id'] not in protected:
            continue
        try:
            mapping = _mapping(conn, row['channel_id'], now)
            if mapping is not None and store.fingerprint(dict(mapping)) == row['mapping_hash']:
                protected.discard(row['channel_id'])
        except (EpgError, ValueError, KeyError, TypeError):
            continue
    return protected


def sync(conn, manifest, channels, paths, now, limit=5):
    """Admit concrete public targets, retaining their existing search floors."""
    if type(limit) is not int or not 1 <= limit <= 5:
        raise EpgError('locked_recovery_batch_limit')
    migrate(conn)
    result = {'implemented': True, 'admittedChannels': 0, 'activeChannels': 0,
              'newMappings': 0, 'newGrants': 0, 'programmesChanged': False}
    if 'epg_coverage_gap_jobs' not in _tables(conn):
        return result
    by_id = {c['id']: c for c in channels}
    selected = conn.execute('''SELECT g.channel_id FROM epg_coverage_gap_jobs g
      JOIN epg_mapping_approvals a ON a.channel_id=g.channel_id AND a.revoked=0 AND a.locked=1
      LEFT JOIN epg_locked_recovery_jobs r ON r.channel_id=g.channel_id
      ORDER BY COALESCE(r.updated_at,0),g.channel_id LIMIT ?''', (limit,)).fetchall()
    for target in selected:
        cid = target['channel_id']
        old = conn.execute('SELECT * FROM epg_locked_recovery_jobs WHERE channel_id=?', (cid,)).fetchone()
        mapping = None
        try:
            if cid in by_id and (old is None or old['enabled']):
                mapping = _mapping(conn, cid, now)
                identity = {k: by_id[cid].get(k) for k in ('id', 'name', 'epgId', 'countryCode', 'regionCode')}
                if mapping is not None and store.fingerprint(identity) != mapping['catalog_identity_hash']:
                    mapping = None
        except (EpgError, ValueError, KeyError, TypeError):
            mapping = None
        if mapping is None:
            if old and old['active']:
                with conn:
                    conn.execute("UPDATE epg_locked_recovery_jobs SET active=0,state='suspended',updated_at=? WHERE channel_id=?", (now, cid))
                    queue.deactivate(conn, cid, now, 'locked_recovery_no_longer_eligible')
            continue
        payload = {**identity, 'categoryPath': paths[cid], 'routeSha256': sorted({
            hashlib.sha256(r['url'].encode()).hexdigest() for r in by_id[cid].get('routes', [])})}
        digest = hashlib.sha256(queue.encoded(payload).encode()).hexdigest()
        mapping_hash = store.fingerprint(dict(mapping))
        changed = old is None or not old['active'] or old['identity_hash'] != digest or old['mapping_hash'] != mapping_hash
        # Mapping changes must also invalidate a previously reviewed identity,
        # even when the catalogue itself did not change. Keep every retry floor.
        if old and old['mapping_hash'] != mapping_hash:
            with conn:
                conn.execute('''UPDATE epg_channel_research_jobs SET identity_evidence=NULL,
                  state='pending_identity',lease_token=NULL,lease_until=0 WHERE channel_id=?''', (cid,))
                if 'epg_research_search_progress' in _tables(conn):
                    conn.execute('UPDATE epg_research_search_progress SET phase_index=0 WHERE channel_id=?', (cid,))
        previous_job = conn.execute('SELECT * FROM epg_channel_research_jobs WHERE channel_id=?', (cid,)).fetchone()
        queue.enqueue(conn, by_id[cid], manifest['version'], paths[cid], now)
        with conn:
            if previous_job:
                conn.execute('UPDATE epg_channel_research_jobs SET next_retry=max(next_retry,?) WHERE channel_id=?',
                             (previous_job['next_retry'], cid))
            conn.execute('''INSERT INTO epg_locked_recovery_jobs
              (channel_id,identity_hash,mapping_hash,state,reason,updated_at) VALUES(?,?,?,'research_only','approved_coverage_missing',?)
              ON CONFLICT(channel_id) DO UPDATE SET identity_hash=excluded.identity_hash,
              mapping_hash=excluded.mapping_hash,active=1,state=excluded.state,reason=excluded.reason,updated_at=excluded.updated_at''',
              (cid, digest, mapping_hash, now))
            if changed:
                queue._audit(conn, {'channel_id': cid, 'identity_hash': digest}, now,
                    'locked_mapping_recovery_admitted', {'mappingFingerprint': mapping_hash,
                    'sourceId': mapping['source_id'], 'originalChannelId': mapping['original_id'],
                    'identityReviewRequired': True, 'mappingReplacementAllowed': False,
                    'cacheRetained': True, 'sourceRetryUnchanged': True, 'newMappings': 0, 'newGrants': 0})
                result['admittedChannels'] += 1
    result['activeChannels'] = conn.execute('SELECT count(*) FROM epg_locked_recovery_jobs WHERE active=1 AND enabled=1').fetchone()[0]
    return result


def eligible_ids(conn, now):
    if 'epg_locked_recovery_jobs' not in _tables(conn):
        return set()
    blocked = research_protected_ids(conn, now)
    return {r[0] for r in conn.execute('SELECT channel_id FROM epg_locked_recovery_jobs WHERE active=1 AND enabled=1')
            if r[0] not in blocked}
