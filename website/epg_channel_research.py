"""Channel-first durable research queue with an explicit identity gate.

Identity review precedes search evidence. This module performs no requests,
creates no programme records or approvals and never edits player mappings.
Use the existing authoritative EPG database connection, not a second database.
"""
import hashlib
import json
import re
import uuid

from epg_ingest import EpgError
from source_registry import validate_public_url

RECORDED_SEARCH_OUTCOMES = frozenset({'not_found', 'waiting_rights', 'waiting_access', 'waiting_validation'})


def encoded(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':'))


def migrate(conn):
    conn.executescript('''
      CREATE TABLE IF NOT EXISTS epg_channel_research_jobs (
        channel_id TEXT PRIMARY KEY, identity_hash TEXT NOT NULL, payload TEXT NOT NULL,
        catalog_version TEXT NOT NULL, priority INTEGER NOT NULL,
        state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
        next_retry INTEGER NOT NULL DEFAULT 0, lease_token TEXT, lease_until INTEGER NOT NULL DEFAULT 0,
        identity_evidence TEXT, updated_at INTEGER NOT NULL, last_error TEXT);
      CREATE TABLE IF NOT EXISTS epg_channel_research_audit (
        id INTEGER PRIMARY KEY, channel_id TEXT NOT NULL, identity_hash TEXT NOT NULL,
        checked_at INTEGER NOT NULL, event TEXT NOT NULL, evidence TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS epg_channel_research_due
        ON epg_channel_research_jobs(next_retry,lease_until,priority);
    ''')
    columns = {row[1] for row in conn.execute('PRAGMA table_info(epg_channel_research_jobs)')}
    if 'active' not in columns:
        conn.execute('ALTER TABLE epg_channel_research_jobs ADD COLUMN active INTEGER NOT NULL DEFAULT 1')
        conn.commit()


def _audit(conn, row, now, event, evidence):
    conn.execute('INSERT INTO epg_channel_research_audit(channel_id,identity_hash,checked_at,event,evidence) VALUES(?,?,?,?,?)',
                 (row['channel_id'], row['identity_hash'], now, event, encoded(evidence)))


def enqueue(conn, channel, catalog_version, category_path, now, *, protected=False):
    """One explicitly selected catalogue channel per call; no provider scan."""
    if protected:
        deactivate(conn, channel['id'], now, 'protected_mapping')
        return False
    if (not isinstance(channel, dict) or not isinstance(channel.get('id'), str)
            or not re.fullmatch(r'[a-zA-Z0-9_-]{1,100}', channel['id'])
            or not isinstance(channel.get('name'), str) or not 1 <= len(channel['name']) <= 256
            or not isinstance(category_path, list) or not 1 <= len(category_path) <= 8
            or any(not isinstance(x, str) or not 1 <= len(x) <= 100 for x in category_path)
            or not isinstance(catalog_version, str) or len(catalog_version) > 100):
        raise EpgError('invalid_research_target')
    routes = channel.get('routes', [])
    if not isinstance(routes, list) or len(routes) > 100:
        raise EpgError('research_route_limit')
    if any(not isinstance(r, dict) or not isinstance(r.get('url'), str)
           or not 1 <= len(r['url']) <= 4096 for r in routes):
        raise EpgError('invalid_research_route')
    payload = {key: channel.get(key) for key in ('id','name','epgId','countryCode','regionCode')}
    payload['categoryPath'] = category_path
    payload['routeSha256'] = sorted({hashlib.sha256(r['url'].encode()).hexdigest() for r in routes})
    body = encoded(payload)
    digest = hashlib.sha256(body.encode()).hexdigest()
    rank = (0 if channel.get('countryCode') in {'CN','HK','MO','TW'} else 10) + int(not any(r.get('lastPlayableAt') for r in routes))
    old = conn.execute('SELECT * FROM epg_channel_research_jobs WHERE channel_id=?', (channel['id'],)).fetchone()
    if old and old['identity_hash'] == digest:
        if not old['active']:
            with conn:
                conn.execute('UPDATE epg_channel_research_jobs SET active=1 WHERE channel_id=?', (channel['id'],))
                _audit(conn, old, now, 'reactivated', {'catalogVersion': catalog_version})
        return False
    with conn:
        conn.execute('''INSERT INTO epg_channel_research_jobs
          (channel_id,identity_hash,payload,catalog_version,priority,state,updated_at)
          VALUES(?,?,?,?,?,'pending_identity',?) ON CONFLICT(channel_id) DO UPDATE SET
          identity_hash=excluded.identity_hash,payload=excluded.payload,catalog_version=excluded.catalog_version,
          priority=excluded.priority,active=1,state='pending_identity',next_retry=0,lease_token=NULL,lease_until=0,
          identity_evidence=NULL,updated_at=excluded.updated_at,last_error='identity_changed' ''',
          (channel['id'],digest,body,catalog_version,rank,now))
        row = {'channel_id': channel['id'], 'identity_hash': digest}
        _audit(conn,row,now,'identity_changed' if old else 'enqueued',{'catalogVersion':catalog_version,'target':payload})
    return True


def deactivate(conn, channel_id, now, reason):
    row = conn.execute('SELECT * FROM epg_channel_research_jobs WHERE channel_id=?', (channel_id,)).fetchone()
    if row is not None and row['active']:
        with conn:
            conn.execute('UPDATE epg_channel_research_jobs SET active=0,lease_token=NULL,lease_until=0 WHERE channel_id=?', (channel_id,))
            _audit(conn, row, now, 'deactivated', {'reason': reason, 'historyRetained': True})


def claim_one(conn, now, *, channel_id=None):
    row = conn.execute('''SELECT * FROM epg_channel_research_jobs
      WHERE active=1 AND next_retry<=? AND lease_until<=? AND (? IS NULL OR channel_id=?)
      ORDER BY priority,next_retry,channel_id LIMIT 1''', (now,now,channel_id,channel_id)).fetchone()
    if row is None:
        return None
    token = uuid.uuid4().hex
    with conn:
        changed = conn.execute('''UPDATE epg_channel_research_jobs SET lease_token=?,lease_until=?,
          next_retry=?,attempts=attempts+1,updated_at=? WHERE channel_id=? AND identity_hash=?
          AND active=1 AND next_retry<=? AND lease_until<=?''',
          (token,now+120,now+3600,now,row['channel_id'],row['identity_hash'],now,now)).rowcount
        if not changed:
            return None
        _audit(conn,row,now,'claimed',{'nextRetryAt':now+3600,'networkRequests':0})
    return dict(conn.execute('SELECT * FROM epg_channel_research_jobs WHERE channel_id=?',(row['channel_id'],)).fetchone())


def _current(conn, claim, now):
    row = conn.execute('SELECT * FROM epg_channel_research_jobs WHERE channel_id=?',(claim['channel_id'],)).fetchone()
    if (row is None or not row['active'] or row['identity_hash'] != claim['identity_hash'] or not claim.get('lease_token')
            or row['lease_token'] != claim['lease_token'] or row['lease_until'] <= now):
        raise EpgError('stale_research_claim')
    return row


def defer_without_search(conn, claim, reason, now, *, retry_after=3600):
    """Persist missing work without inventing identity review or search results."""
    row = _current(conn, claim, now)
    if (reason not in {'identity_review_required', 'search_executor_unavailable'}
            or type(retry_after) is not int or not 900 <= retry_after <= 7 * 86400
            or (reason == 'search_executor_unavailable' and not row['identity_evidence'])):
        raise EpgError('invalid_research_deferral')
    state = 'pending_identity' if reason == 'identity_review_required' else 'waiting_executor'
    error = reason
    retained_outcome = None
    if reason == 'search_executor_unavailable' and row['state'] in RECORDED_SEARCH_OUTCOMES:
        # A missing executor did not recheck permission, access, source quality
        # or availability. Keep the last actual channel-search result visible.
        retained_outcome = state = row['state']
        error = row['last_error']
    retry = max(row['next_retry'], now + retry_after)
    with conn:
        changed = conn.execute('''UPDATE epg_channel_research_jobs SET state=?,next_retry=?,lease_token=NULL,
          lease_until=0,updated_at=?,last_error=? WHERE channel_id=? AND identity_hash=? AND active=1
          AND lease_token=? AND lease_until>?''',
          (state,retry,now,error,row['channel_id'],claim['identity_hash'],claim['lease_token'],now)).rowcount
        if changed != 1:
            raise EpgError('stale_research_claim')
        _audit(conn,row,now,'blocked_without_search',{'reason':reason,'nextRetryAt':retry,
            'retainedSearchOutcome':retained_outcome,
            'networkRequests':0,'identityAutomaticallyApproved':False,'newMappings':0,'newGrants':0})
    return retry


def record_identity_observation(conn, channel_id, identity_hash, sources, findings, now, *, retry_after=21600):
    """Archive a partial review without claiming a search or approving identity.

    An operator review may finish while the scheduler has already parked the
    same channel. Preserve its attempt counter and every existing retry floor.
    The identity digest and inactive/leased/reviewed guards prevent attaching
    evidence to a different feed or modifying a protected mapping.
    """
    if (not isinstance(channel_id, str) or not re.fullmatch(r'[a-zA-Z0-9_-]{1,100}', channel_id)
            or not isinstance(identity_hash, str) or not re.fullmatch(r'[a-f0-9]{64}', identity_hash)
            or type(now) is not int or now < 0
            or type(retry_after) is not int or not 900 <= retry_after <= 7 * 86400
            or not isinstance(sources, list) or not 1 <= len(sources) <= 8
            or not isinstance(findings, list) or not 1 <= len(findings) <= 20
            or any(not isinstance(item, str) or not 1 <= len(item) <= 1000 for item in findings)):
        raise EpgError('invalid_identity_observation')
    for source in sources:
        if (not isinstance(source, dict) or set(source) != {'url', 'result', 'reason'}
                or any(not isinstance(source[k], str) or not 1 <= len(source[k]) <= 1000
                       for k in ('result', 'reason'))):
            raise EpgError('invalid_identity_observation')
        validate_public_url(source['url'])
    with conn:
        changed = conn.execute('''UPDATE epg_channel_research_jobs SET
          next_retry=max(next_retry,?),updated_at=?,last_error='identity_review_required',
          lease_token=NULL,lease_until=0 WHERE channel_id=? AND identity_hash=? AND active=1
          AND state='pending_identity' AND identity_evidence IS NULL AND lease_until<=?''',
          (now + retry_after, now, channel_id, identity_hash, now)).rowcount
        if changed != 1:
            raise EpgError('stale_identity_observation')
        row = conn.execute('SELECT * FROM epg_channel_research_jobs WHERE channel_id=?', (channel_id,)).fetchone()
        _audit(conn, row, now, 'partial_identity_observation', {'sources': sources, 'findings': findings,
            'nextRetryAt': row['next_retry'], 'identityApproved': False, 'programmeSearchPerformed': False,
            'newMappings': 0, 'newGrants': 0, 'published': False})
    return row['next_retry']


def confirm_identity(conn, claim, facts, now, *, explicitly_reviewed=False):
    row = _current(conn,claim,now)
    required = {'fullName','operator','countryCode','channelNumber','language','feedVariant','categoryPath','evidenceUrls'}
    if (explicitly_reviewed is not True or not isinstance(facts,dict) or set(facts)!=required
            or any(not isinstance(facts[k],str) or not 1<=len(facts[k])<=256
                   for k in ('fullName','operator','countryCode','channelNumber','language','feedVariant'))
            or not isinstance(facts['evidenceUrls'],list) or not 1<=len(facts['evidenceUrls'])<=8):
        raise EpgError('research_identity_evidence_required')
    target = json.loads(row['payload'])
    if facts['countryCode'] != target['countryCode'] or facts['categoryPath'] != target['categoryPath']:
        raise EpgError('research_target_context_mismatch')
    for url in facts['evidenceUrls']:
        validate_public_url(url)
    with conn:
        changed = conn.execute("UPDATE epg_channel_research_jobs SET identity_evidence=?,state='search_pending',updated_at=? WHERE channel_id=? AND identity_hash=? AND lease_token=? AND lease_until>?",
                     (encoded(facts),now,row['channel_id'],claim['identity_hash'],claim['lease_token'],now)).rowcount
        if changed != 1:
            raise EpgError('stale_research_claim')
        _audit(conn,row,now,'identity_reviewed_for_research',facts)


def _validate_search_evidence(terms, sources, outcome, retry_after):
    if (outcome not in RECORDED_SEARCH_OUTCOMES
            or type(retry_after) is not int or not 900<=retry_after<=7*86400
            or not isinstance(terms,list) or not 1<=len(terms)<=12
            or any(not isinstance(t,str) or not 1<=len(t)<=300 for t in terms)
            or not isinstance(sources,list) or len(sources)>20):
        raise EpgError('invalid_research_search_evidence')
    for source in sources:
        if (not isinstance(source,dict) or set(source)!={'url','result','reason'}
                or any(not isinstance(source[k],str) or not 1<=len(source[k])<=1000 for k in ('result','reason'))):
            raise EpgError('invalid_research_source_evidence')
        validate_public_url(source['url'])


def record_search(conn, claim, terms, sources, outcome, now, *, retry_after=21600):
    row = _current(conn,claim,now)
    if not row['identity_evidence']:
        raise EpgError('research_identity_before_search')
    _validate_search_evidence(terms, sources, outcome, retry_after)
    retry = max(row['next_retry'],now+retry_after)
    with conn:
        changed = conn.execute('''UPDATE epg_channel_research_jobs SET state=?,next_retry=?,lease_token=NULL,
          lease_until=0,updated_at=?,last_error=? WHERE channel_id=? AND identity_hash=? AND lease_token=? AND lease_until>?''',
          (outcome,retry,now,outcome,row['channel_id'],claim['identity_hash'],claim['lease_token'],now)).rowcount
        if changed != 1:
            raise EpgError('stale_research_claim')
        _audit(conn,row,now,'search_recorded',{'terms':terms,'sources':sources,'outcome':outcome,
                    'nextRetryAt':retry,'newMappings':0,'newGrants':0,'published':False})
    return retry


def record_expired_search_observation(conn, claim, terms, sources, outcome, now,
                                      *, completed_not_after, retry_after=21600):
    """Archive a completed review after its original lease expired, without renewal.

    The original claim must still own the unchanged, approved search-pending
    identity. A newer claim, scheduler deferral, changed feed or protected job
    rejects the observation. The completion bound must lie within that lease.
    This operation never grants data rights or performs another search.
    """
    _validate_search_evidence(terms, sources, outcome, retry_after)
    row = conn.execute('SELECT * FROM epg_channel_research_jobs WHERE channel_id=?',
                       (claim['channel_id'],)).fetchone()
    if (type(now) is not int or type(completed_not_after) is not int or row is None
            or not row['active'] or row['state'] != 'search_pending' or not row['identity_evidence']
            or row['identity_hash'] != claim['identity_hash'] or not claim.get('lease_token')
            or row['lease_token'] != claim['lease_token'] or row['lease_until'] != claim['lease_until']
            or not row['updated_at'] <= completed_not_after < row['lease_until'] <= now
            or now - row['lease_until'] > 7 * 86400):
        raise EpgError('stale_completed_search_observation')
    retry = max(row['next_retry'], now + retry_after)
    with conn:
        changed = conn.execute('''UPDATE epg_channel_research_jobs SET state=?,next_retry=?,lease_token=NULL,
          lease_until=0,updated_at=?,last_error=? WHERE channel_id=? AND identity_hash=? AND active=1
          AND state='search_pending' AND identity_evidence=? AND lease_token=? AND lease_until=? AND updated_at=?''',
          (outcome, retry, now, outcome, row['channel_id'], row['identity_hash'], row['identity_evidence'],
           claim['lease_token'], claim['lease_until'], row['updated_at'])).rowcount
        if changed != 1:
            raise EpgError('stale_completed_search_observation')
        _audit(conn, row, now, 'completed_search_observation', {'terms': terms, 'sources': sources,
            'outcome': outcome, 'completedNotAfter': completed_not_after, 'originalLeaseExpired': True,
            'leaseRenewed': False, 'nextRetryAt': retry, 'newMappings': 0, 'newGrants': 0, 'published': False})
    return retry
