"""Durable observed publication deltas and evidence blockers for every search run.

Queue growth and response counts are never EPG coverage. Deltas observe the
shared publisher; they do not attribute concurrent admin work to AI searches.
"""
import gzip
import hashlib
import json
from pathlib import Path
import sqlite3


def capture(conn, directory, now):
    from epg_coverage import summarize
    import epg_store as store
    coverage = summarize(conn, now, Path(directory)/'public')
    result = {'checkedAtUtc': now, 'coverage': coverage, 'publishedIds': None}
    if not coverage['publishedSnapshotVerifiedLocally']:
        return result
    manifest = store.active_manifest(conn)
    raw = (Path(directory)/'public/snapshots'/(manifest['sha256']+'.json.gz')).read_bytes()
    if hashlib.sha256(raw).hexdigest() != manifest['sha256']:
        return result
    payload = json.loads(gzip.decompress(raw))
    approved = set()
    for item in payload['channels']:
        try:
            store._approved(conn, item['id'])
            approved.add(item['id'])
        except (ValueError, TypeError, KeyError):
            continue
    current = {p['channelId'] for p in payload['programmes'] if p['startUtc'] <= now < p['stopUtc']}
    future = {p['channelId'] for p in payload['programmes'] if p['startUtc'] > now}
    ids = sorted(current & future & approved)
    if len(ids) == coverage['publishedCurrentAndFutureChannels']:
        result['publishedIds'] = ids
    return result


def blockers(conn):
    tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    out = {'identityReviewStates': {}, 'sourceCandidateStates': {}, 'sourceHealthStates': {}}
    if {'epg_research_evidence_reviews','epg_channel_research_jobs'} <= tables:
        out['identityReviewStates'] = {r[0]:r[1] for r in conn.execute('''
          SELECT e.state,count(*) FROM epg_research_evidence_reviews e
          JOIN epg_channel_research_jobs j ON j.channel_id=e.channel_id
            AND j.identity_hash=e.identity_hash AND j.active=1
          GROUP BY e.state''')}
        out['missingIdentityFields'] = {r[0]:r[1] for r in conn.execute('''
          SELECT f.value,count(DISTINCT e.channel_id) FROM epg_research_evidence_reviews e
          JOIN epg_channel_research_jobs j ON j.channel_id=e.channel_id
            AND j.identity_hash=e.identity_hash AND j.active=1
          JOIN json_each(e.packet,'$.unresolvedFields') f GROUP BY f.value''')}
    if 'epg_research_http_cache' in tables:
        out['programmeResponseNextActionsByUrl'] = {r[0]:r[1] for r in conn.execute('''
          SELECT json_extract(result,'$.nextAction'),count(*) FROM epg_research_http_cache
          WHERE json_extract(result,'$.contentInspectionVersion')=2
          GROUP BY json_extract(result,'$.nextAction')''')}
    if 'epg_research_source_candidates' in tables:
        out['sourceCandidateStates'] = {r[0]:r[1] for r in conn.execute('''
          SELECT s.state,count(DISTINCT s.channel_id) FROM epg_research_source_candidates s
          JOIN epg_channel_research_jobs j ON j.channel_id=s.channel_id
            AND j.identity_hash=s.identity_hash AND j.active=1
          GROUP BY s.state''')}
    if 'source_health' in tables:
        out['sourceHealthStates'] = {r[0]:r[1] for r in conn.execute('SELECT state,count(*) FROM source_health GROUP BY state')}
        out['sourceHealthErrors'] = {r[0]:r[1] for r in conn.execute(
            'SELECT last_error,count(*) FROM source_health WHERE last_error IS NOT NULL GROUP BY last_error')}
    out['countsAreSeparateStagesNotAdditive'] = True
    return out


def record(conn, directory, started_at, *, before=None, execution=None, now=None, kind='automatic_search'):
    import time
    now = int(time.time() if now is None else now)
    after = capture(conn, directory, now)
    conn.execute('''CREATE TABLE IF NOT EXISTS epg_exploration_rounds(
      id INTEGER PRIMARY KEY,started_at INTEGER NOT NULL,finished_at INTEGER NOT NULL,
      kind TEXT NOT NULL,receipt TEXT NOT NULL)''')
    baseline = conn.execute("SELECT value FROM epg_checkpoints WHERE name='epg_round_publication_baseline'").fetchone()
    previous = before if before is not None else json.loads(baseline[0]) if baseline else after
    valid = previous.get('publishedIds') is not None and after['publishedIds'] is not None
    added = sorted(set(after['publishedIds'])-set(previous['publishedIds'])) if valid else None
    removed = sorted(set(previous['publishedIds'])-set(after['publishedIds'])) if valid else None
    execution = execution or {}
    receipt = {'kind':kind,'startedAtUtc':started_at,'finishedAtUtc':now,
        'coverageBefore':previous['coverage']['publishedCurrentAndFutureChannels'] if valid else None,
        'coverageAfter':after['coverage']['publishedCurrentAndFutureChannels'] if valid else None,
        'addedPublishedChannelIds':added,'removedPublishedChannelIds':removed,
        'netPublishedCoverageChange':len(added)-len(removed) if valid else None,
        'publishedSnapshotVerified':after['coverage']['publishedSnapshotVerifiedLocally'],
        'aiRequestsAttempted':execution.get('aiRequestsAttempted',0),
        'sourceBodyChecksAttempted':execution.get('sourceCheckAttempts',0),
        'sourceBodiesActuallyRead':execution.get('sourceBodiesRead',0),
        'programmeResponsesActuallyRead':execution.get('programmeResponsesRead',0),
        'identitiesConfirmed':execution.get('identitiesConfirmedThisRun',0),
        'queueAdmissionsAreNotCoverage':True,'deltaAttribution':'observed_shared_publication',
        'blockers':blockers(conn)}
    with conn:
        row = conn.execute('INSERT INTO epg_exploration_rounds(started_at,finished_at,kind,receipt) VALUES(?,?,?,?)',
            (started_at,now,kind,json.dumps(receipt,sort_keys=True)))
        receipt['roundId'] = row.lastrowid
        conn.execute('INSERT OR REPLACE INTO epg_checkpoints VALUES(?,?)',
            ('epg_last_exploration_round',json.dumps(receipt,sort_keys=True)))
        if after['publishedIds'] is not None:
            conn.execute('INSERT OR REPLACE INTO epg_checkpoints VALUES(?,?)',
                ('epg_round_publication_baseline',json.dumps(after,sort_keys=True)))
    return receipt
