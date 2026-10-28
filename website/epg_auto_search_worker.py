"""Persistent channel-first search: bounded serial batches, durable rotation and backoff.

Unconfirmed identities stay behind the identity gate. Search and technical HTTP
evidence do not create mappings, data grants, programmes or public snapshots.
"""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import sqlite3
import time
import uuid

import epg_auto_search as search
import epg_channel_research as queue
import epg_evidence_review as review
from epg_channel_research_worker import load_targets, protected_ids
from epg_ingest import database, EpgError

CHECKPOINT = 'channel_auto_search'
CONTROL = 'channel_auto_search_control'
EXECUTION = 'channel_auto_search_last_execution'
SQLITE_BUSY_WAIT_MS = 5000


def migrate(conn):
    queue.migrate(conn)
    review.migrate(conn)
    conn.executescript('''
      CREATE TABLE IF NOT EXISTS epg_checkpoints(name TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS epg_research_http_cache(
        url TEXT PRIMARY KEY,checked_at INTEGER NOT NULL,result TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS epg_research_search_progress(
        channel_id TEXT PRIMARY KEY,identity_hash TEXT NOT NULL,phase_index INTEGER NOT NULL);
    ''')


def read_checkpoint(conn, name):
    row = conn.execute('SELECT value FROM epg_checkpoints WHERE name=?', (name,)).fetchone()
    return json.loads(row[0]) if row else {}


def execution_receipt(conn, now, result=None, error=None):
    """Publish execution health separately from the last completed search batch.

    A partial batch may already have committed channel audits. Never replace
    that progress or reset claims/retry floors after an infrastructure failure.
    Error messages can contain private data and must never enter this receipt.
    """
    receipt = {'checkedAtUtc': now, 'state': 'deferred' if error is not None else result['state'],
               'safeError': 'auto_search_worker_check_failed' if error is not None else result.get('safeError'),
               'auditHistoryRetained': True, 'retryFloorsRetained': True}
    if error is not None:
        phases = {'run', 'sync_known', 'choose', 'claim_target', 'checked_candidates',
                  'finish', 'finish_review', 'stage_identity', 'validate_one_source', 'save_checkpoint',
                  'load_targets', 'migrate', '_audit', 'enqueue'}
        trace = error.__traceback__
        while trace is not None:
            name = trace.tb_frame.f_code.co_name
            if name in phases:
                receipt['errorPhase'] = name
            trace = trace.tb_next
        if isinstance(error, sqlite3.Error):
            receipt['errorFamily'] = 'sqlite'
            code = getattr(error, 'sqlite_errorname', '')
            allowed = {'SQLITE_BUSY', 'SQLITE_LOCKED', 'SQLITE_READONLY', 'SQLITE_FULL', 'SQLITE_IOERR',
                       'SQLITE_CONSTRAINT', 'SQLITE_ERROR', 'SQLITE_INTERRUPT', 'SQLITE_CANTOPEN'}
            receipt['sqliteCode'] = code if code in allowed else 'SQLITE_OTHER'
        elif isinstance(error, EpgError):
            receipt['errorFamily'] = 'epg_validation'
        elif isinstance(error, OSError):
            receipt['errorFamily'] = 'io'
        else:
            receipt['errorFamily'] = 'invalid_data'
    else:
        receipt['claimedChannels'] = result.get('claimedChannels', 0)
        receipt['finishedAtUtc'] = result.get('finishedAtUtc', now)
    # A failed SQL statement may leave a transaction open. Roll it back before
    # the independent receipt; earlier per-channel commits remain untouched.
    if error is not None:
        conn.rollback()
    try:
        with conn:
            conn.execute('INSERT OR REPLACE INTO epg_checkpoints(name,value) VALUES(?,?)',
                         (EXECUTION, queue.encoded(receipt)))
        receipt['durable'] = True
    except sqlite3.Error:
        conn.rollback()
        receipt['durable'] = False
    return receipt


def save_checkpoint(conn, result):
    previous = read_checkpoint(conn, CHECKPOINT)
    accepted = [v['channelId'] for v in result.get('processedChannels', []) if v.get('searchEvidenceAccepted')]
    if accepted:
        result.update(lastAcceptedSearchAtUtc=result.get('finishedAtUtc', result['checkedAtUtc']),
                      lastAcceptedChannelIds=accepted)
    else:
        for key in ('lastAcceptedSearchAtUtc', 'lastAcceptedChannelIds'):
            if key in previous:
                result[key] = previous[key]
    with conn:
        conn.execute('INSERT OR REPLACE INTO epg_checkpoints(name,value) VALUES(?,?)', (CHECKPOINT, queue.encoded(result)))
        conn.execute('INSERT OR REPLACE INTO epg_checkpoints(name,value) VALUES(?,?)', ('channel_research', queue.encoded(result)))
    return result


def control(conn, now, error, retry_at=None, manual=False):
    value = read_checkpoint(conn, CONTROL)
    value = {'safeError': error, 'checkedAtUtc': now,
             'requiresManualAction': manual or value.get('requiresManualAction', False),
             'retryAtUtc': max(value.get('retryAtUtc') or 0, retry_at or now + 3600)}
    with conn:
        conn.execute('INSERT OR REPLACE INTO epg_checkpoints(name,value) VALUES(?,?)', (CONTROL, queue.encoded(value)))


def target_hash(channel, path):
    payload = {k: channel.get(k) for k in ('id', 'name', 'epgId', 'countryCode', 'regionCode')}
    payload.update(categoryPath=path, routeSha256=sorted({hashlib.sha256(r['url'].encode()).hexdigest() for r in channel.get('routes', [])}))
    return hashlib.sha256(queue.encoded(payload).encode()).hexdigest()


def sync_known(conn, manifest, channels, paths, now):
    by_id, protected = {c['id']: c for c in channels}, protected_ids(conn)
    for row in conn.execute('SELECT channel_id FROM epg_channel_research_jobs').fetchall():
        cid = row[0]
        if cid not in by_id:
            queue.deactivate(conn, cid, now, 'catalog_channel_removed')
        else:
            queue.enqueue(conn, by_id[cid], manifest['version'], paths[cid], now, protected=cid in protected)
    return by_id, protected


def research_priority(channel, path=None):
    """Public category hints affect scheduling only, never identity facts.

    Missing country metadata must not push a Taiwan/HK/Macao catalogue target
    behind every explicitly regional target. An explicit nonregional country
    still takes precedence over a contradictory category. Do not persist the
    hint into the catalogue, identity evidence, or the legacy discovery queue.
    """
    country = channel.get('countryCode')
    regional = country in {'CN', 'HK', 'MO', 'TW'}
    if country in (None, ''):
        regional = any(part in {'中国', '中國', '香港', '澳门', '澳門', '台湾', '台灣', '臺灣'}
                       for part in (path or []))
    playable = any(route.get('lastPlayableAt') for route in channel.get('routes', []))
    return (0 if regional else 10) + int(not playable)


def choose(conn, manifest, channels, paths, protected, now, handled):
    # Previously due cases rotate first. An exhausted/incomplete channel has a
    # persisted future retry and cannot monopolize this batch or the next one.
    rows = conn.execute('''SELECT * FROM epg_channel_research_jobs WHERE active=1
      AND next_retry<=? AND lease_until<=?
      ORDER BY priority/10,CASE WHEN identity_evidence IS NOT NULL THEN 0 ELSE 1 END,
      priority,next_retry,channel_id''', (now, now)).fetchall()
    by_id = {c['id']: c for c in channels}
    # Apply the same scheduling hint to retained jobs and newly selected
    # targets. Earlier jobs must not keep camera/name-only cases ahead of
    # clear broadcast targets solely because their IDs were admitted first.
    # This is never an identity decision: all jobs and retry floors survive.
    eligible = [r for r in rows if r['channel_id'] in by_id
                and r['channel_id'] not in handled and r['channel_id'] not in protected]
    # Recompute from current public metadata for both old and new jobs. Keep
    # stored identities, attempts, evidence, leases and retry floors unchanged.
    # Retain the existing within-bucket playability score. This change only
    # repairs regional grouping, not the stored public playback observations.
    ranks = {r['channel_id']: 10 * (research_priority(by_id[r['channel_id']], paths[r['channel_id']]) // 10)
             + r['priority'] % 10
             for r in eligible}
    eligible.sort(key=lambda r: (ranks[r['channel_id']] // 10,
        0 if r['identity_evidence'] is not None else 1, ranks[r['channel_id']],
        broadcast_rank(by_id[r['channel_id']], paths[r['channel_id']]),
        r['next_retry'], r['channel_id']))
    row = next(iter(eligible), None)
    if row:
        return row
    known = {r[0] for r in conn.execute('SELECT channel_id FROM epg_channel_research_jobs')}
    channel = next((c for c in sorted(channels, key=lambda c: (research_priority(c, paths[c['id']]), broadcast_rank(c, paths[c['id']]), c['id']))
                    if c['id'] not in known and c['id'] not in protected and c['id'] not in handled), None)
    if channel is None:
        return None
    # Admit a single real public target, never a bulk provider/source scan.
    queue.enqueue(conn, channel, manifest['version'], paths[channel['id']], now)
    return conn.execute('SELECT * FROM epg_channel_research_jobs WHERE channel_id=?', (channel['id'],)).fetchone()


def broadcast_rank(channel, path=None):
    """A scheduling hint only. Never evidence of identity or programme content."""
    import re
    name = channel['name']
    if any(re.fullmatch(r'(?:广播|廣播|電臺|电台|央視|央视)', part) for part in (path or [])):
        return 0
    if re.search(r'(?:CCTV|CGTN|电视|電視|卫视|衛視|广播|廣播|電臺|电台|新闻综合|新聞綜合|\bTV\b|\bRadio\b|\bFM\b|\bAM\b)', name, re.I):
        return 0
    return 1


def phase(conn, row):
    value = conn.execute('SELECT identity_hash,phase_index FROM epg_research_search_progress WHERE channel_id=?', (row['channel_id'],)).fetchone()
    return value[1] if value and value[0] == row['identity_hash'] else 0


def claim_target(conn, expected, now, *, admit=None):
    """CAS the planned identity and review, not whichever row replaced it."""
    token = uuid.uuid4().hex
    conn.execute('BEGIN IMMEDIATE')
    try:
        if expected['channel_id'] in protected_ids(conn):
            conn.rollback()
            return None
        if admit is not None:
            eligible = conn.execute('''SELECT 1 FROM epg_channel_research_jobs
              WHERE channel_id=? AND identity_hash=? AND payload=? AND identity_evidence IS ?
              AND state=? AND active=1 AND next_retry<=? AND lease_until<=?''',
              (expected['channel_id'], expected['identity_hash'], expected['payload'],
               expected['identity_evidence'], expected['state'], now, now)).fetchone()
            if eligible is None:
                conn.rollback()
                return None
            # Acquire the EPG writer before recording a shared AI reservation.
            # Admission is a local DB operation, never a network call. A full
            # shared window rolls back without changing attempts/retry floors.
            admit()
        changed = conn.execute('''UPDATE epg_channel_research_jobs SET lease_token=?,lease_until=?,
          next_retry=?,attempts=attempts+1,updated_at=? WHERE channel_id=? AND identity_hash=?
          AND payload=? AND identity_evidence IS ? AND state=? AND active=1
          AND next_retry<=? AND lease_until<=?''',
          (token, now + 120, now + 3600, now, expected['channel_id'], expected['identity_hash'],
           expected['payload'], expected['identity_evidence'], expected['state'], now, now)).rowcount
        if changed != 1:
            conn.rollback()
            return None
        row = conn.execute('SELECT * FROM epg_channel_research_jobs WHERE channel_id=?', (expected['channel_id'],)).fetchone()
        queue._audit(conn, row, now, 'channel_auto_search_claimed', {'networkRequests': 0, 'nextRetryAt': row['next_retry']})
        conn.commit()
        return dict(row)
    except BaseException:
        conn.rollback()
        raise


def checked_candidates(conn, evidence, request, now, checker):
    checks = []
    for candidate in evidence['candidates'][:2]:
        url = candidate['url']
        # Recheck the current phase policy before consulting historical cache.
        # Keep legal old cache/audits intact, but do not reuse programme pages
        # as identity evidence after an identity or policy transition.
        if not search.candidate_allowed(url, request['domains'], request['stage'], request=request):
            evidence.setdefault('phaseExcludedReferences', []).append({
                'urlSha256': hashlib.sha256(url.encode()).hexdigest(),
                'reason': 'candidate_phase_or_access_policy_rejected'})
            continue
        cached = conn.execute('SELECT checked_at,result FROM epg_research_http_cache WHERE url=?', (url,)).fetchone()
        if cached and now - cached[0] < 21600:
            check = json.loads(cached[1])
            # A shared page is not downloaded again for a different target;
            # target-specific snippets from the first check are not reused.
            check.update(cacheReused=True, selectedIdentityRechecked=False, originalCheckedAtUtc=cached[0])
            check.pop('selectedNameExcerpts', None)
            if isinstance(check.get('visibleText'), str) and request['stage'] == 'identity':
                check.update(search.inspect_text(check['visibleText'], request, source_url=check.get('url')))
                references = set(check.get('bodyReferenceSha256', []))
                check['linkedRouteSha256'] = sorted({hashlib.sha256(url.encode()).hexdigest()
                    for url in request.get('catalogRoutes', []) if hashlib.sha256(url.encode()).hexdigest() in references})
        else:
            try:
                check = checker(url, request)
            except (OSError, TimeoutError, ValueError):
                check = {'url': url, 'result': 'bounded_check_failed', 'bodyBytes': 0,
                         'reason': 'Bounded technical check failed; not adopted.'}
            check.update(checkedAtUtc=now, cacheReused=False)
            with conn:
                conn.execute('INSERT OR REPLACE INTO epg_research_http_cache VALUES(?,?,?)', (url, now, queue.encoded(check)))
                conn.execute('DELETE FROM epg_research_http_cache WHERE url IN (SELECT url FROM epg_research_http_cache ORDER BY checked_at DESC,url LIMIT -1 OFFSET 500)')
        checks.append(check)
    return checks


def finish(conn, claim, request, evidence, now, *, error=None, retry_at=None, manual=False):
    conn.execute('BEGIN IMMEDIATE')
    try:
        row = queue._current(conn, claim, now)
        if row['channel_id'] in protected_ids(conn):
            raise EpgError('auto_search_protected_mapping')
        newly_reviewed = bool(row['identity_evidence']) and not claim['identity_evidence']
        advanced = bool(evidence and evidence.get('sourceValidationHandoffs')) or newly_reviewed
        delay = 900 if advanced and not error else min(7 * 86400, 21600 * 2 ** min(max(0, row['attempts'] - 1), 5))
        retry = max(row['next_retry'], retry_at or now + delay)
        state = row['state'] if row['identity_evidence'] else 'pending_identity'
        if row['identity_evidence'] and state not in queue.RECORDED_SEARCH_OUTCOMES:
            state = 'waiting_validation'
        reason = error or ('identity_review_required' if not row['identity_evidence'] else state)
        changed = conn.execute('''UPDATE epg_channel_research_jobs SET state=?,next_retry=?,
          lease_token=NULL,lease_until=0,updated_at=?,last_error=? WHERE channel_id=?
          AND identity_hash=? AND lease_token=? AND lease_until>? AND active=1''',
          (state, retry, now, reason, row['channel_id'], claim['identity_hash'], claim['lease_token'], now)).rowcount
        if changed != 1:
            raise EpgError('auto_search_stale_claim')
        # Full bounded documents belong to the review packet/cache, not every
        # search audit. Preserve hashes, excerpts and check/review outcomes.
        audited_evidence = None if evidence is None else {**evidence, 'technicalChecks': [
            {k: v for k, v in check.items() if k not in {'visibleText', 'bodyReferenceSha256'}}
            for check in evidence.get('technicalChecks', [])]}
        queue._audit(conn, row, now, 'channel_auto_search_finished', {
            'stage': request['stage'], 'catalogueIdentity': json.loads(row['payload']),
            'requestedQuery': request['query'], 'searchEvidence': audited_evidence,
            'safeError': error, 'requiresManualAction': manual, 'nextRetryAt': retry,
            'identityReviewed': bool(row['identity_evidence']),
            'identityAutomaticallyApproved': newly_reviewed, 'programmeSearchPerformed': request['stage'] != 'identity',
            'newMappings': 0, 'newGrants': 0, 'newProgrammeRows': 0, 'published': False})
        if evidence is not None and request['stage'] != 'identity':
            index = phase(conn, row) + 1
            conn.execute('INSERT OR REPLACE INTO epg_research_search_progress VALUES(?,?,?)', (row['channel_id'], row['identity_hash'], index))
        if manual:
            conn.execute('INSERT OR REPLACE INTO epg_checkpoints VALUES(?,?)', (CONTROL, queue.encoded({
                'checkedAtUtc': now, 'safeError': error, 'requiresManualAction': True, 'retryAtUtc': retry})))
        conn.commit()
        return retry
    except BaseException:
        conn.rollback()
        raise


def run(conn, manifest, channels, paths, settings_factory, shared_database, *, max_channels=3,
        max_seconds=150, clock=time.time, monotonic=time.monotonic, transport=search.transport,
        reserve=search.reserve_shared_budget, checker=search.check_candidate, reload_targets=None, source_directory=None,
        route_directory_checker=None, route_directory_due=None):
    if type(max_channels) is not int or not 1 <= max_channels <= 5 or not 60 <= max_seconds <= 180:
        raise EpgError('auto_search_invalid_batch_limit')
    if (not isinstance(channels, list) or len(channels) > 10000
            or len({c['id'] for c in channels}) != len(channels)):
        raise EpgError('invalid_research_catalog')
    migrate(conn)
    now, started = int(clock()), monotonic()
    result = {'schemaVersion': 1, 'stage': 'channel_first_automatic_search', 'checkedAtUtc': now,
        'catalogVersion': manifest['version'], 'catalogChannels': len(channels), 'state': 'idle',
        'networkSearchExecutorImplemented': True, 'identityAutomaticallyApproved': False,
        'legacyCountryProviderDiscoveryEnabled': False, 'aiRequestsAttempted': 0,
        'sourceCheckAttempts': 0,
        'claimedChannels': 0, 'processedChannels': [], 'newMappings': 0,
        'identityReviewExecutorImplemented': True, 'identitiesConfirmedThisRun': 0,
        'identityEvidencePacketsStaged': 0, 'sourceValidationHandoffs': 0,
        'newGrants': 0, 'newProgrammeRows': 0, 'published': False}
    by_id, protected = sync_known(conn, manifest, channels, paths, now)
    result['cachedIdentityEvidenceRecovery'] = review.recover_one_cached_identity(conn, now, protected)
    result['identityEvidencePacketsStaged'] += result['cachedIdentityEvidenceRecovery']['recoveredChannels']
    # Public source checks need no AI request and must not stop just because
    # the shared model admission window is full.
    if source_directory is not None:
        result['sourceValidation'] = review.validate_one_source(conn, source_directory, now)
    # Opt-in exact-route metadata is separate from model admission. It only
    # observes the selected target and cannot grant identity or EPG rights.
    pause = read_checkpoint(conn, CONTROL)
    metadata_requests = 0
    if route_directory_checker is not None and not pause.get('requiresManualAction'):
        checked_targets = route_directory_due(conn, now, channels, paths) if route_directory_due is not None else set()
        selected = choose(conn, manifest, channels, paths, protected_ids(conn), now, checked_targets)
        if selected is not None:
            cid = selected['channel_id']
            result['routeDirectoryIdentity'] = {'channelId': cid, 'name': by_id[cid]['name'],
                **route_directory_checker(conn, selected, by_id[cid], paths[cid], now)}
            metadata_requests = int(bool(result['routeDirectoryIdentity'].get('networkRequests')))
    result['routeDirectoryEvidence'] = review.attach_one_directory_observation(conn, now, protected_ids(conn)) if max_channels > metadata_requests else {'state': 'batch_budget_deferred', 'attachedChannels': 0}
    if pause.get('requiresManualAction') or pause.get('retryAtUtc', 0) > now:
        return save_checkpoint(conn, {**result,
            'state': 'waiting_manual_action' if pause.get('requiresManualAction') else 'waiting_shared_admission',
            'requiresManualAction': pause.get('requiresManualAction', False),
            'safeError': pause.get('safeError'), 'admissionRetryAtUtc': pause.get('retryAtUtc'),
            'nextRetryAtUtc': pause.get('retryAtUtc')})
    handled = set()
    for _ in range(max_channels - metadata_requests - result['routeDirectoryEvidence']['attachedChannels']):
        # Reserve enough wall time for a 45s API request and two bounded checks.
        if monotonic() - started > max_seconds - 60:
            break
        now = int(clock())
        # Pending checked evidence is reviewed before spending more quota on
        # web search. This local stage preserves each channel's network floor.
        task = review.pending(conn, now)
        if task is not None and task['channel_id'] not in handled:
            cid = task['channel_id']
            result.update(selectedChannelId=cid, selectedChannelName=by_id[cid]['name'],
                          selectedCategoryPath=paths[cid], identityReviewed=False)
            try:
                settings = settings_factory()
                search.validate_settings(settings)
                claim = review.claim_review(conn, task, now, protected_ids(conn),
                    admit=lambda: reserve(shared_database, now))
            except search.SearchDeferred as exc:
                control(conn, now, exc.code, exc.retry_at, exc.requires_manual_action)
                result.update(state='waiting_shared_admission', safeError=exc.code, nextRetryAtUtc=exc.retry_at)
                break
            except (OSError, ValueError, KeyError, TypeError):
                control(conn, now, 'auto_search_configuration_review_required', manual=True)
                result.update(state='waiting_manual_action', safeError='auto_search_configuration_review_required', requiresManualAction=True)
                break
            if claim is None:
                continue
            handled.add(cid)
            result['claimedChannels'] += 1
            result['aiRequestsAttempted'] += 1
            response, error, retry = None, None, None
            try:
                response = transport(settings, review.review_request(json.loads(task['packet']), settings['model']))
                if reload_targets is not None:
                    fresh_manifest, fresh_channels, fresh_paths = reload_targets()
                    sync_known(conn, fresh_manifest, fresh_channels, fresh_paths, int(clock()))
                if cid in protected_ids(conn):
                    raise EpgError('auto_search_protected_mapping')
                item = review.finish_review(conn, claim, task, response, int(clock()))
            except search.SearchDeferred as exc:
                error, retry = exc.code, exc.retry_at
                control(conn, int(clock()), error, retry, exc.requires_manual_action)
                item = review.finish_review(conn, claim, task, None, int(clock()), error=error, retry_at=retry)
            except (OSError, ValueError, KeyError, TypeError):
                try:
                    item = review.finish_review(conn, claim, task, None, int(clock()),
                        error='identity_review_evidence_rejected', retry_at=int(clock()) + 21600)
                except EpgError:
                    item = {'channelId': cid, 'stage': 'identity_review', 'state': 'stale_result_rejected',
                            'identityReviewed': False, 'safeError': 'auto_search_stale_claim'}
            result['processedChannels'].append(item)
            result['identitiesConfirmedThisRun'] += int(item['identityReviewed'])
            result.update(state='progressed', nextRetryAtUtc=item.get('nextRetryAtUtc'))
            if error:
                break
            continue
        row = choose(conn, manifest, channels, paths, protected_ids(conn), now, handled)
        if row is None:
            break
        cid = row['channel_id']
        channel = by_id[cid]
        handled.add(cid)
        if target_hash(channel, paths[cid]) != row['identity_hash']:
            raise EpgError('auto_search_target_changed')
        try:
            facts = json.loads(row['identity_evidence']) if row['identity_evidence'] else None
            request = search.plan(channel, paths[cid], facts, row['attempts'], phase(conn, row), review.search_hint(conn, row, now))
        except (ValueError, KeyError, TypeError):
            claim = claim_target(conn, row, now)
            if claim is not None:
                retry = finish(conn, claim, {'stage': 'identity', 'query': ''}, None, now,
                               error='auto_search_identity_evidence_requires_review', retry_at=now + 86400)
                result['processedChannels'].append({'channelId': cid, 'name': channel['name'],
                    'state': 'invalid_identity_parked', 'auditRecorded': True, 'nextRetryAtUtc': retry})
            continue
        result.update(selectedChannelId=cid, selectedChannelName=channel['name'],
                      selectedCategoryPath=paths[cid], identityReviewed=bool(facts))
        try:
            settings = settings_factory()
            search.validate_settings(settings)
            request['body']['model'] = settings['model']
            claim = claim_target(conn, row, now, admit=lambda: reserve(shared_database, now))
        except search.SearchDeferred as exc:
            control(conn, now, exc.code, exc.retry_at, exc.requires_manual_action)
            result.update(state='waiting_shared_admission', safeError=exc.code, nextRetryAtUtc=exc.retry_at)
            break
        except (OSError, ValueError, KeyError, TypeError):
            control(conn, now, 'auto_search_configuration_review_required', manual=True)
            result.update(state='waiting_manual_action', safeError='auto_search_configuration_review_required', requiresManualAction=True)
            break
        if claim is None:
            continue
        result['claimedChannels'] += 1
        result['aiRequestsAttempted'] += 1
        evidence, error, retry, manual = None, None, None, False
        global_wait = False
        try:
            evidence = search.decode(transport(settings, request['body']), request, int(clock()))
            evidence['technicalChecks'] = checked_candidates(conn, evidence, request, int(clock()), checker)
            result['sourceCheckAttempts'] += sum(not check.get('cacheReused', False) for check in evidence['technicalChecks'])
        except search.SearchDeferred as exc:
            error, retry, manual = exc.code, exc.retry_at, exc.requires_manual_action
            retry = now + 7 * 86400 if manual else retry
            global_wait = manual or 'rate_limit' in error or 'protocol' in error
        except (OSError, TimeoutError):
            error, retry = 'auto_search_transport_unavailable', now + 3600
        except (ValueError, TypeError, KeyError):
            error, retry = 'auto_search_response_requires_review', now + 21600
        # Re-read the actual immutable catalogue before accepting a result.
        # In-flight route/category drift never inherits the old review.
        if reload_targets is not None:
            fresh_manifest, fresh_channels, fresh_paths = reload_targets()
            sync_known(conn, fresh_manifest, fresh_channels, fresh_paths, int(clock()))
        try:
            if evidence is not None:
                if request['stage'] == 'identity':
                    staged = review.stage_identity(conn, claim, request, evidence, int(clock()))
                    result['identityEvidencePacketsStaged'] += int(staged is not None)
                    evidence['identityReviewPacketStaged'] = staged is not None
                    evidence['identityReviewReady'] = bool(staged)
                    if staged and evidence.get('identityReviewProposal') is not None:
                        task = conn.execute('SELECT * FROM epg_research_evidence_reviews WHERE channel_id=? AND identity_hash=?',
                                            (cid, claim['identity_hash'])).fetchone()
                        proposal = {'status': 'completed', 'output': [{'type': 'message', 'content': [
                            {'type': 'output_text', 'text': queue.encoded(evidence['identityReviewProposal'])}]}]}
                        try:
                            outcome = review.finish_review(conn, claim, task, proposal, int(clock()), keep_claim=True)
                            result['identitiesConfirmedThisRun'] += int(outcome['identityReviewed'])
                            evidence['sameRequestIdentityReview'] = outcome['state']
                        except (ValueError, KeyError, TypeError):
                            evidence['sameRequestIdentityReview'] = 'checked_page_evidence_incomplete'
                else:
                    handoffs = review.handoff_sources(conn, claim, request, evidence, int(clock()))
                    result['sourceValidationHandoffs'] += len(handoffs)
                    evidence['sourceValidationHandoffs'] = handoffs
            next_retry = finish(conn, claim, request, evidence, int(clock()), error=error, retry_at=retry, manual=manual)
            identity_reviewed = bool(conn.execute('SELECT identity_evidence FROM epg_channel_research_jobs WHERE channel_id=?', (cid,)).fetchone()[0])
            item = {'channelId': cid, 'name': channel['name'], 'stage': request['stage'],
                    'identityReviewed': identity_reviewed, 'safeError': error,
                    'state': 'identity_pending_backoff' if not identity_reviewed else 'source_validation_pending_backoff',
                    'nextRetryAtUtc': next_retry, 'auditRecorded': True,
                    'searchEvidenceAccepted': evidence is not None,
                    'candidateCount': len(evidence['candidates']) if evidence else 0,
                    'technicalCheckCount': len(evidence.get('technicalChecks', [])) if evidence else 0}
        except EpgError:
            item = {'channelId': cid, 'name': channel['name'], 'state': 'stale_result_rejected',
                    'safeError': 'auto_search_stale_claim', 'auditRecorded': False}
        result['processedChannels'].append(item)
        result.update(state='progressed', nextRetryAtUtc=item.get('nextRetryAtUtc'))
        if global_wait:
            control(conn, int(clock()), error, retry, manual)
            result.update(state='waiting_manual_action' if manual else 'waiting_upstream', safeError=error,
                          requiresManualAction=manual, admissionRetryAtUtc=retry)
            break
    result.update(activeJobs=conn.execute('SELECT count(*) FROM epg_channel_research_jobs WHERE active=1').fetchone()[0],
                  finishedAtUtc=int(clock()))
    result['identityAutomaticallyApproved'] = bool(result['identitiesConfirmedThisRun'])
    return save_checkpoint(conn, result)


def main():
    from catalog_inventory import DATA
    from server_worker import config
    from server_jobs import database as shared_database
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir', type=Path, default=Path(DATA))
    parser.add_argument('--max-channels', type=int, default=3)
    parser.add_argument('--exact-route-identity', action='store_true',
                        help='Check one selected radio route in the bounded public metadata directory')
    args = parser.parse_args()
    directory = args.data_dir / 'epg'
    with (directory / 'auto-search.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(json.dumps({'state': 'already_running', 'aiRequestsAttempted': 0}))
            return
        conn = database(directory)
        # Bound contention without making brief publisher writes lose the
        # search batch and its independent health receipt after just one second.
        conn.execute('PRAGMA busy_timeout='+str(SQLITE_BUSY_WAIT_MS))
        try:
            manifest, channels, paths = load_targets(args.data_dir)
            directory_checker = None
            directory_due = None
            if args.exact_route_identity:
                import epg_route_directory
                directory_due = epg_route_directory.recent_target_ids
                def directory_checker(conn, row, channel, path, now):
                    def current_identity():
                        _, current_channels, current_paths = load_targets(args.data_dir)
                        current = next((c for c in current_channels if c['id'] == channel['id']), None)
                        return target_hash(current, current_paths[current['id']]) if current else None
                    return epg_route_directory.check_selected(conn, row, channel, path, now,
                        reload_selected=current_identity)
            result = run(conn, manifest, channels, paths, config, shared_database,
                max_channels=args.max_channels, reload_targets=lambda: load_targets(args.data_dir), source_directory=directory,
                route_directory_checker=directory_checker, route_directory_due=directory_due)
            result['executionHealth'] = execution_receipt(conn, int(time.time()), result=result)
            print(json.dumps(result, ensure_ascii=False))
        except (OSError, ValueError, KeyError, TypeError, sqlite3.Error) as exc:
            print(json.dumps(execution_receipt(conn, int(time.time()), error=exc)))
        finally:
            conn.close()


if __name__ == '__main__':
    main()
