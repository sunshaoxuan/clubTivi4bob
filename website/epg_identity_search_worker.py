"""Persistent identity-only canary for one reviewed catalogue feed.

The broader queue remains a read-only due selector. This worker never
automatically approves identity, follows candidate pages, parses schedules,
changes mappings/grants or publishes programme data.
"""
import fcntl
import hashlib
import json
from pathlib import Path
import sqlite3
import time
import uuid

import epg_channel_research as queue
from epg_channel_research_worker import load_targets
from epg_ingest import EpgError, database
import epg_identity_search as search

CHECKPOINT = 'identity_search_guangdong'
SUSPENSION = CHECKPOINT + '_suspension'


def protected(conn):
    return bool(conn.execute('SELECT 1 FROM epg_mapping_approvals WHERE channel_id=? AND revoked=0',
                             (search.CHANNEL_ID,)).fetchone())


def checkpoint(conn, result):
    with conn:
        previous = conn.execute('SELECT value FROM epg_checkpoints WHERE name=?', (CHECKPOINT,)).fetchone()
        previous = json.loads(previous[0]) if previous else {}
        if result['aiRequestsAttempted']:
            result['lastAttemptAtUtc'] = result['checkedAtUtc']
            result['lastSearchAtUtc'] = result['checkedAtUtc'] if result.get('searchEvidence') else previous.get('lastSearchAtUtc')
        else:
            for key in ('lastAttemptAtUtc', 'lastSearchAtUtc'):
                if key in previous:
                    result[key] = previous[key]
        if result.get('requiresManualAction'):
            conn.execute('INSERT OR IGNORE INTO epg_checkpoints(name,value) VALUES(?,?)',
                (SUSPENSION, queue.encoded({'checkedAtUtc': result['checkedAtUtc'],
                 'safeError': result.get('safeError'), 'requiresManualAction': True})))
        conn.execute('INSERT OR REPLACE INTO epg_checkpoints(name,value) VALUES(?,?)',
                     (CHECKPOINT, queue.encoded(result)))
    return result


def claim_target(conn, expected, now):
    """Atomically claim only this unchanged, pending and unprotected identity."""
    token = uuid.uuid4().hex
    conn.execute('BEGIN IMMEDIATE')
    try:
        if protected(conn):
            conn.rollback()
            return None
        changed = conn.execute('''UPDATE epg_channel_research_jobs SET lease_token=?,lease_until=?,
          next_retry=?,attempts=attempts+1,updated_at=? WHERE channel_id=? AND identity_hash=?
          AND payload=? AND active=1 AND next_retry<=? AND lease_until<=?
          AND state='pending_identity' AND identity_evidence IS NULL''',
          (token, now + 120, now + 3600, now, search.CHANNEL_ID, expected['identity_hash'],
           expected['payload'], now, now)).rowcount
        if changed != 1:
            conn.rollback()
            return None
        row = conn.execute('SELECT * FROM epg_channel_research_jobs WHERE channel_id=?',
                           (search.CHANNEL_ID,)).fetchone()
        queue._audit(conn, row, now, 'identity_search_claimed',
                     {'networkRequests': 0, 'nextRetryAt': row['next_retry']})
        conn.commit()
        return dict(row)
    except BaseException:
        conn.rollback()
        raise


def finish(conn, claim, evidence, now, *, error=None, retry_at=None, manual=False):
    """One guarded transaction; stale claims cannot attach evidence to a new feed."""
    conn.execute('BEGIN IMMEDIATE')
    try:
        row = queue._current(conn, claim, now)
        if row['state'] != 'pending_identity' or row['identity_evidence'] is not None or protected(conn):
            raise EpgError('identity_search_stale_target')
        floor = max(row['next_retry'], retry_at or now + min(7 * 86400, 21600 * 2 ** min(row['attempts'] - 1, 5)))
        changed = conn.execute('''UPDATE epg_channel_research_jobs SET next_retry=?,
          lease_token=NULL,lease_until=0,updated_at=?,last_error=?
          WHERE channel_id=? AND identity_hash=? AND lease_token=? AND lease_until>?
          AND active=1 AND state='pending_identity' AND identity_evidence IS NULL''',
          (floor, now, error or 'identity_review_required', row['channel_id'], claim['identity_hash'],
           claim['lease_token'], now)).rowcount
        if changed != 1:
            raise EpgError('identity_search_stale_target')
        queue._audit(conn, row, now, 'bounded_identity_search_finished',
            {'searchEvidence': evidence, 'safeError': error, 'requiresManualAction': manual,
             'nextRetryAt': floor, 'identityApproved': False, 'programmeSearchPerformed': False,
             'newMappings': 0, 'newGrants': 0, 'newProgrammeRows': 0, 'published': False})
        if manual:
            conn.execute('INSERT OR IGNORE INTO epg_checkpoints(name,value) VALUES(?,?)',
                (SUSPENSION, queue.encoded({'checkedAtUtc': now, 'safeError': error,
                                          'requiresManualAction': True})))
        conn.commit()
        return floor
    except BaseException:
        conn.rollback()
        raise


def run(conn, manifest, channels, paths, settings_factory, shared_database, *,
        clock=time.time, transport=search.transport, reserve=search.reserve_shared_budget):
    now = int(clock())
    result = {'schemaVersion': 1, 'stage': 'one_channel_identity_search_canary', 'checkedAtUtc': now,
        'channelId': search.CHANNEL_ID, 'channelName': search.NAME, 'catalogVersion': manifest['version'],
        'identityApproved': False, 'programmeSearchPerformed': False, 'aiRequestsAttempted': 0,
        'sourceBodiesFetched': 0, 'newMappings': 0, 'newGrants': 0, 'newProgrammeRows': 0,
        'published': False, 'broaderAutonomousDiscoveryImplemented': False}
    row = conn.execute('SELECT * FROM epg_channel_research_jobs WHERE channel_id=?',
                       (search.CHANNEL_ID,)).fetchone()
    if row is None:
        return checkpoint(conn, {**result, 'state': 'reviewed_case_missing'})
    result.update(identityHash=row['identity_hash'], nextRetryAtUtc=row['next_retry'])
    suspended = conn.execute('SELECT value FROM epg_checkpoints WHERE name=?', (SUSPENSION,)).fetchone()
    if suspended:
        return checkpoint(conn, {**result, 'state': 'waiting_manual_action',
            'requiresManualAction': True, 'safeError': json.loads(suspended[0]).get('safeError')})
    try:
        channel = next(c for c in channels if c['id'] == search.CHANNEL_ID)
        payload = search.target_payload(channel, paths[search.CHANNEL_ID])
        if (queue.encoded(payload) != row['payload']
                or hashlib.sha256(queue.encoded(payload).encode()).hexdigest() != row['identity_hash']):
            raise EpgError('identity_search_target_review_required')
    except (StopIteration, KeyError, EpgError):
        return checkpoint(conn, {**result, 'state': 'reviewed_target_changed',
                                 'safeError': 'identity_search_target_review_required'})
    if protected(conn) or not row['active'] or row['identity_evidence'] is not None or row['state'] != 'pending_identity':
        return checkpoint(conn, {**result, 'state': 'outside_identity_canary_scope'})
    previous = conn.execute('SELECT value FROM epg_checkpoints WHERE name=?', (CHECKPOINT,)).fetchone()
    previous = json.loads(previous[0]) if previous else {}
    if previous.get('identityHash') == row['identity_hash']:
        if previous.get('requiresManualAction'):
            return checkpoint(conn, {**result, 'state': 'waiting_manual_action',
                'requiresManualAction': True, 'safeError': previous.get('safeError')})
        if previous.get('admissionRetryAtUtc', 0) > now:
            return checkpoint(conn, {**result, 'state': 'waiting_shared_budget',
                'safeError': 'search_budget_deferred', 'admissionRetryAtUtc': previous['admissionRetryAtUtc']})
    if now >= search.POLICY_EXPIRES:
        return checkpoint(conn, {**result, 'state': 'policy_review_required'})
    if row['next_retry'] > now or row['lease_until'] > now:
        return checkpoint(conn, {**result, 'state': 'waiting_recorded_retry'})
    try:
        settings = settings_factory()
        search.validate_settings(settings)
        body = search.request_body(settings.get('model'))
        # A budget deferral does not claim a case, consume an attempt or move
        # its real research floor. Reservation history is never reset.
        reserve(shared_database, now)
    except search.SearchDeferred as exc:
        return checkpoint(conn, {**result, 'state': 'waiting_shared_budget',
            'safeError': exc.code, 'admissionRetryAtUtc': exc.retry_at})
    except (EpgError, OSError, ValueError, TypeError):
        return checkpoint(conn, {**result, 'state': 'waiting_manual_action',
            'safeError': 'identity_search_configuration_review_required', 'requiresManualAction': True})
    result['sharedBudgetReservations'] = 1
    claim = claim_target(conn, row, now)
    if claim is None:
        return checkpoint(conn, {**result, 'state': 'claim_changed_before_request'})
    result['aiRequestsAttempted'] = 1
    evidence, error, manual, retry = None, None, False, None
    try:
        evidence = search.decode(transport(settings, body), int(clock()))
        result['state'] = 'identity_candidates_require_review'
        result['searchEvidence'] = evidence
    except search.SearchDeferred as exc:
        error, manual, retry = exc.code, exc.requires_manual_action, exc.retry_at
        retry = now + 7 * 86400 if manual else retry
        result['state'] = 'waiting_manual_action' if manual else 'search_deferred'
    except EpgError:
        error, retry = 'identity_search_response_not_accepted', now + 21600
        result['state'] = 'response_requires_review'
    except (OSError, TimeoutError, ValueError, TypeError):
        error, retry = 'identity_search_transport_unavailable', now + 3600
        result['state'] = 'search_deferred'
    result.update(safeError=error, requiresManualAction=manual)
    try:
        result['nextRetryAtUtc'] = finish(conn, claim, evidence, int(clock()),
            error=error, retry_at=retry, manual=manual)
        result['auditRecorded'] = True
    except EpgError:
        result.update(state='result_rejected_stale_claim', auditRecorded=False,
                      safeError='identity_search_stale_target')
        result.pop('searchEvidence', None)
    return checkpoint(conn, result)


def main():
    from catalog_inventory import DATA
    from server_jobs import database as shared_database
    from server_worker import config
    root = Path(DATA)
    directory = root / 'epg'
    with (directory / 'identity-search-guangdong.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(json.dumps({'state': 'already_running', 'aiRequestsAttempted': 0}))
            return
        conn = database(directory)
        try:
            manifest, channels, paths = load_targets(root)
            result = run(conn, manifest, channels, paths, config, shared_database)
            print(json.dumps(result, ensure_ascii=False))
        except (EpgError, OSError, ValueError, KeyError, sqlite3.Error):
            # Exceptions can contain endpoint/response text, so only a fixed
            # safe code is emitted. A claimed crash keeps its 1h retry floor.
            print(json.dumps({'state': 'deferred', 'safeError': 'identity_search_worker_check_failed'}))
        finally:
            conn.close()


if __name__ == '__main__':
    main()
