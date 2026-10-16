"""Bounded, metadata-only rediscovery after sustained source degradation.

This queue rechecks already reviewed provider entries. It does not approve a
channel, fetch another URL, supersede a source or activate a programme feed.
Broader provider search and exact-identity review remain separate requirements.
"""
from collections import Counter
import hashlib
import json
from urllib.parse import urlsplit

from epg_ingest import EpgError

API = 'https://api.tvmaze.com/schedule'
# Country search scopes, not evidence that any individual feed is equivalent.
# Bind each scope to its reviewed URL so reusing an ID cannot widen access.
XML_SCOPES = {
    'cn-zsdc-existing': ('https://epg.zsdc.eu.org/t.xml.gz', 'CN'),
    'cn-112114-existing': ('https://epg.112114.xyz/pp.xml', 'CN'),
    'hk-iptv-epg-reviewed-redirect-v1': ('https://iptv-epg.org/files/epg-hk.xml.gz', 'HK'),
}


def migrate(conn):
    conn.executescript('''
      CREATE TABLE IF NOT EXISTS epg_source_recovery_jobs (
        source_id TEXT PRIMARY KEY, country TEXT NOT NULL, active INTEGER NOT NULL,
        priority INTEGER NOT NULL, state TEXT NOT NULL, reason TEXT NOT NULL,
        first_seen INTEGER NOT NULL, last_checked INTEGER NOT NULL,
        next_review INTEGER NOT NULL, evidence_hash TEXT NOT NULL, evidence TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS epg_source_recovery_audit (
        id INTEGER PRIMARY KEY, source_id TEXT NOT NULL, checked_at INTEGER NOT NULL,
        state TEXT NOT NULL, evidence_hash TEXT NOT NULL, evidence TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS epg_source_recovery_due
        ON epg_source_recovery_jobs(active,next_review,priority);
    ''')


def country_scope(source):
    if (source.get('id') == 'cctv2-official-diagnostic-v1'
            and source.get('format') == 'cctv-json'
            and source.get('url') == 'https://api.cntv.cn/epg/getEpgInfoByChannelNew'
            and source.get('channelId') == 'cctv2' and source.get('countryCode') == 'CN'
            and source.get('calendarTimezone') == 'Asia/Shanghai'):
        return 'CN'
    if (source.get('format') == 'tvmaze-json' and source.get('url') == API
            and isinstance(source.get('countryCode'), str)
            and len(source['countryCode']) == 2 and source['countryCode'].isascii()
            and source['countryCode'].isalpha() and source['countryCode'].isupper()):
        return source['countryCode']
    scope = XML_SCOPES.get(source.get('id'))
    return scope[1] if scope and source.get('url') == scope[0] else None


def problem(conn, health, source, now):
    if (health['last_error'] in ('http_401', 'http_403', 'source_configuration_changed')
            or health['url'] != source['url']
            or health['configuration'] != json.dumps(source, sort_keys=True)):
        return 'manual_access_or_configuration_review'
    if health['failures'] >= 3:
        return 'sustained_fetch_failure'
    if health['last_success'] is not None:
        quality = json.loads(health['last_good_quality'] or 'null') or {}
        end = quality.get('coverageEndUtc')
        if type(end) is int and end <= now:
            return 'last_good_coverage_expired'
        if now - health['last_success'] > 2 * source['refreshSeconds']:
            return 'source_refresh_overdue'
    recent = conn.execute('''SELECT state FROM probe_audit WHERE source_id=?
      AND state IN ('healthy','partial','failed') ORDER BY id DESC LIMIT 3''', (source['id'],)).fetchall()
    if len(recent) == 3 and all(row['state'] == 'partial' for row in recent):
        return 'sustained_partial_coverage'
    return None


def candidate(conn, source, health, now):
    if (health is None or health['state'] not in ('healthy', 'partial')
            or health['last_success'] is None or health['failures']
            or now - health['last_success'] > 2 * source['refreshSeconds']
            or health['configuration'] != json.dumps(source, sort_keys=True)):
        return None
    quality = json.loads(health['last_good_quality'] or 'null') or {}
    end = quality.get('coverageEndUtc')
    identities = conn.execute('SELECT count(*) FROM source_identities WHERE source_id=?', (source['id'],)).fetchone()[0]
    if type(end) is not int or end <= now or not identities:
        return None
    from epg_store import reviewed_data_use
    try:
        rights = reviewed_data_use(conn, source['id'])
    except (EpgError, ValueError, TypeError, KeyError):
        rights = None
    return {'sourceId': source['id'], 'sourceUrl': source['url'],
        'lastSuccessfulProbe': health['last_success'], 'contentSha256': health['content_sha256'],
        'coverageEndUtc': end, 'sourceIdentities': identities, 'probeState': health['state'],
        'programmeDataRightsVerified': bool(rights),
        'dataReviewFingerprint': rights.get('reviewFingerprint') if rights else None,
        'exactCatalogIdentityVerified': False, 'automaticallyApplied': False,
        'validationBasis': 'last_successful_bounded_probe_not_new_fetch_or_catalogue_coverage'}


def run(conn, sources, channels, now, limit=5):
    if type(limit) is not int or not 1 <= limit <= 5:
        raise EpgError('recovery_batch_size_limit')
    migrate(conn)
    counts = Counter(row.get('countryCode') for row in channels)
    scoped = {source['id']: source for source in sources
        if country_scope(source) is not None and country_scope(source) in counts}
    health = {row['id']: row for row in conn.execute('SELECT * FROM source_health')}
    existing = {row['source_id']: row for row in conn.execute('SELECT * FROM epg_source_recovery_jobs')}
    # Select due existing jobs first; new problems share the same bounded batch.
    eligible = []
    for identity, source in scoped.items():
        previous = existing.get(identity)
        row = health.get(identity)
        if row is None or row['state'] in ('superseded', 'probing'):
            continue
        reason = problem(conn, row, source, now)
        if (reason or previous and previous['active']) and (not previous or previous['next_review'] <= now):
            country = country_scope(source)
            eligible.append((0 if country in ('CN', 'HK', 'MO', 'TW') else 10,
                previous['next_review'] if previous else 0, identity, reason))
    checked = 0
    with conn:
        for previous in existing.values():
            if previous['active'] and previous['source_id'] not in scoped:
                conn.execute('UPDATE epg_source_recovery_jobs SET active=0,state=? WHERE source_id=?',
                    ('inactive_source', previous['source_id']))
        for rank, _, identity, reason in sorted(eligible)[:limit]:
            checked += 1
            source, row = scoped[identity], health[identity]
            country = country_scope(source)
            alternatives = []
            if reason != 'manual_access_or_configuration_review':
                for other_id, other in sorted(scoped.items()):
                    if (other_id == identity or country_scope(other) != country
                            or urlsplit(other['url']).netloc == urlsplit(source['url']).netloc):
                        continue
                    value = candidate(conn, other, health.get(other_id), now)
                    if value:
                        alternatives.append(value)
            state = ('recovered' if reason is None else 'manual_review'
                if reason == 'manual_access_or_configuration_review' else
                'candidates_require_review' if alternatives else 'needs_alternative_provider')
            evidence = {'sourceId': identity, 'sourceUrl': source['url'], 'countrySearchScope': country,
                'catalogChannelsInCountry': counts[country], 'reason': reason,
                'failures': row['failures'], 'lastSuccess': row['last_success'],
                'lastFailure': row['last_failure'], 'nextSourceRetry': row['next_retry'],
                'sourceProbeState': row['state'], 'alternatives': alternatives,
                'newNetworkRequests': 0, 'newGrants': 0, 'newMappings': 0, 'published': False}
            encoded = json.dumps(evidence, sort_keys=True)
            digest = hashlib.sha256(encoded.encode()).hexdigest()
            previous = existing.get(identity)
            if previous is None or previous['evidence_hash'] != digest or previous['state'] != state:
                conn.execute('INSERT INTO epg_source_recovery_audit(source_id,checked_at,state,evidence_hash,evidence) VALUES(?,?,?,?,?)',
                    (identity, now, state, digest, encoded))
            conn.execute('''INSERT INTO epg_source_recovery_jobs VALUES(?,?,?,?,?,?,?,?,?,?,?)
              ON CONFLICT(source_id) DO UPDATE SET country=excluded.country,active=excluded.active,
              priority=excluded.priority,state=excluded.state,reason=excluded.reason,last_checked=excluded.last_checked,
              next_review=excluded.next_review,evidence_hash=excluded.evidence_hash,evidence=excluded.evidence''',
                (identity, country, int(reason is not None), rank, state, reason or 'source_recovered',
                 previous['first_seen'] if previous else now, now, now + 300, digest, encoded))
    return {'checkedSources': checked, 'batchLimit': limit, 'newNetworkRequests': 0,
        'jobStates': dict(conn.execute('SELECT state,count(*) FROM epg_source_recovery_jobs WHERE active=1 GROUP BY state')),
        'automaticMappingApproval': False, 'automaticSourceReplacement': False, 'published': False}
