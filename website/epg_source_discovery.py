"""Persistent bounded provider discovery. Metadata candidates, never approvals.

Only the reviewed TVmaze schedule endpoint is supported in this revision.
Provider discovery does not establish an exact catalogue feed or public coverage.
"""
import argparse
from collections import Counter
import fcntl
import json
from pathlib import Path
import time

from catalog_inventory import DATA
from epg_discovery import load_catalog, migrate as discovery_schema, priority
from epg_ingest import EpgError, database, probe_batch, registry

CALENDARS = {
    'HK': 'Asia/Hong_Kong', 'MO': 'Asia/Macau', 'TW': 'Asia/Taipei',
    'FR': 'Europe/Paris', 'CA': 'America/Toronto', 'JP': 'Asia/Tokyo',
    'DE': 'Europe/Berlin', 'IT': 'Europe/Rome', 'GR': 'Europe/Athens',
    'KR': 'Asia/Seoul', 'AU': 'Australia/Sydney', 'NZ': 'Pacific/Auckland',
    'ES': 'Europe/Madrid', 'NL': 'Europe/Amsterdam',
}
# Honour the live manual diagnostics already performed before this worker existed.
# These are one-time lower bounds, not timestamps fabricated as successful fetches.
BOOTSTRAP_NOT_BEFORE = {'DE': 1792154884, 'IT': 1792156653, 'GR': 1792156667}
API = 'https://api.tvmaze.com/schedule'


def source_for(country):
    if country not in CALENDARS:
        raise EpgError('unsupported_discovery_country')
    return {
        'id': 'tvmaze-discovery-' + country.lower() + '-v1', 'url': API,
        'format': 'tvmaze-json', 'countryCode': country,
        'calendarTimezone': CALENDARS[country], 'redirectUrls': [],
        'refreshSeconds': 3600, 'publicationAllowed': False,
        'scope': 'Bounded persistent provider discovery; identity candidates only',
        'dataLicense': {'status': 'programme_data_license_evidence_found',
            'name': 'CC BY-SA 4.0', 'reviewedAt': '2026-10-16',
            'evidenceUrl': 'https://www.tvmaze.com/api',
            'licenseUrl': 'https://creativecommons.org/licenses/by-sa/4.0/',
            'restriction': 'Attribution, license link, transformation notice and ShareAlike required. '
                'This diagnostic creates no data grant, exact feed mapping or public schedule.'}}


def migrate(conn):
    discovery_schema(conn)
    conn.executescript('''
      CREATE TABLE IF NOT EXISTS epg_source_discovery_jobs (
        source_id TEXT PRIMARY KEY, country TEXT NOT NULL, active INTEGER NOT NULL,
        priority INTEGER NOT NULL, catalog_channels INTEGER NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending', failures INTEGER NOT NULL DEFAULT 0,
        first_seen INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        last_attempt INTEGER, next_retry INTEGER NOT NULL DEFAULT 0,
        lease_until INTEGER NOT NULL DEFAULT 0, last_error TEXT);
      CREATE INDEX IF NOT EXISTS epg_source_discovery_due
        ON epg_source_discovery_jobs(active,state,next_retry,priority);
      CREATE TABLE IF NOT EXISTS epg_source_discovery_audit (
        id INTEGER PRIMARY KEY, source_id TEXT NOT NULL, checked_at INTEGER NOT NULL,
        event TEXT NOT NULL, evidence TEXT NOT NULL);
    ''')


def audit(conn, source_id, now, event, evidence):
    conn.execute('INSERT INTO epg_source_discovery_audit(source_id,checked_at,event,evidence) VALUES(?,?,?,?)',
        (source_id, now, event, json.dumps(evidence, sort_keys=True)))


def retain_effective_retry(conn, source):
    # Both consumers must see the longer persisted cooldown. Never shorten a
    # Retry-After or queue backoff, or modify a different source configuration.
    conn.execute('''UPDATE source_health SET next_retry=MAX(next_retry,
      COALESCE((SELECT next_retry FROM epg_source_discovery_jobs WHERE source_id=?),0))
      WHERE id=? AND url=? AND configuration=? AND state!='superseded' ''',
        (source['id'], source['id'], source['url'], json.dumps(source, sort_keys=True)))


def sync_jobs(conn, channels, configured, now):
    # Public catalogue country and playback evidence only. Private favourites,
    # user sources and player mappings are not read or uploaded.
    existing = {s.get('countryCode') for s in configured
        if s.get('format') == 'tvmaze-json' and s.get('url') == API}
    counts = Counter(c.get('countryCode') for c in channels)
    priorities = {country: min(priority(c) for c in channels if c.get('countryCode') == country)
        for country in CALENDARS if counts[country] and country not in existing}
    with conn:
        conn.execute('UPDATE epg_source_discovery_jobs SET active=0')
        for country, rank in priorities.items():
            source_id = source_for(country)['id']
            inserted = conn.execute('''INSERT OR IGNORE INTO epg_source_discovery_jobs
              (source_id,country,active,priority,catalog_channels,first_seen,updated_at,next_retry)
              VALUES(?,?,1,?,?,?,?,?)''', (source_id, country, rank, counts[country], now, now,
                BOOTSTRAP_NOT_BEFORE.get(country, 0))).rowcount
            conn.execute('''UPDATE epg_source_discovery_jobs SET active=1,priority=?,catalog_channels=?,updated_at=?
              WHERE source_id=?''', (rank, counts[country], now, source_id))
            conn.execute('''UPDATE epg_source_discovery_jobs SET next_retry=MAX(next_retry,
              COALESCE((SELECT next_retry FROM source_health WHERE id=?),0)) WHERE source_id=?''',
                (source_id, source_id))
            retain_effective_retry(conn, source_for(country))
            if inserted:
                audit(conn, source_id, now, 'queued', {'country': country,
                    'catalogChannels': counts[country], 'publicationAllowed': False})


def run(directory, manifest, channels, configured, now=None, fetcher=None):
    """One serial country fetch; caller owns the shared worker.lock."""
    now = int(time.time() if now is None else now)
    conn = database(directory)
    try:
        migrate(conn)
        sync_jobs(conn, channels, configured, now)
        checkpoint = conn.execute("SELECT value FROM epg_checkpoints WHERE name='source_discovery'").fetchone()
        previous = json.loads(checkpoint[0]) if checkpoint else {}
        rate_limit = conn.execute("SELECT max(next_retry) FROM source_health WHERE url=? AND state!='superseded' AND last_error='http_429'", (API,)).fetchone()[0] or 0
        provider_retry = max(previous.get('providerRetryAtUtc', 0), rate_limit)
        with conn:
            interrupted = conn.execute("SELECT * FROM epg_source_discovery_jobs WHERE state='probing' AND lease_until<=?", (now,)).fetchall()
            for job in interrupted:
                conn.execute("UPDATE epg_source_discovery_jobs SET state='failed',failures=failures+1,lease_until=0,last_error='worker_interrupted' WHERE source_id=?", (job['source_id'],))
                audit(conn, job['source_id'], now, 'interrupted', {'nextRetryAtUtc': job['next_retry']})
        due = conn.execute('''SELECT * FROM epg_source_discovery_jobs WHERE active=1
          AND state NOT IN ('manual_review','probing') AND next_retry<=?
          ORDER BY priority,next_retry,source_id LIMIT 1''', (now,)).fetchone() if now >= provider_retry else None
        selected, error = None, None
        if due:
            selected = due['source_id']
            source = source_for(due['country'])
            with conn:
                # A crash cannot cause minute-by-minute retries of the same URL.
                conn.execute("UPDATE epg_source_discovery_jobs SET state='probing',last_attempt=?,next_retry=?,lease_until=?,updated_at=? WHERE source_id=?",
                    (now, now + 3600, now + 120, now, selected))
                audit(conn, selected, now, 'probing', {'catalogVersion': manifest['version']})
            try:
                probe_batch(directory, [source], now, fetcher=fetcher, batch_size=1)
                health = conn.execute('SELECT * FROM source_health WHERE id=?', (selected,)).fetchone()
                if health is None:
                    raise EpgError('missing_probe_receipt')
                error = health['last_error']
                failures = due['failures'] + 1 if error else 0
                retry = max(health['next_retry'], now + (min(86400, 3600 * 2 ** min(failures - 1, 5)) if error else 3600))
                state = 'manual_review' if error in ('http_401', 'http_403') else health['state']
                quality = json.loads(health['last_attempt_quality'] or 'null')
                if error == 'http_429':
                    provider_retry = max(provider_retry, retry)
                    with conn:
                        conn.execute('UPDATE source_health SET next_retry=? WHERE id=?', (retry, selected))
            except (EpgError, OSError) as exc:
                error = str(exc) if isinstance(exc, EpgError) else 'local_worker_failure'
                state, failures = 'manual_review', due['failures'] + 1
                retry, quality = now + 86400, None
            with conn:
                conn.execute('''UPDATE epg_source_discovery_jobs SET state=?,failures=?,next_retry=?,
                  lease_until=0,last_error=?,updated_at=? WHERE source_id=?''',
                    (state, failures, retry, error, now, selected))
                audit(conn, selected, now, state, {'safeError': error, 'nextRetryAtUtc': retry,
                    'quality': quality, 'programmeStorageRequiresExistingGrantAndExactMapping': True, 'newGrants': 0,
                    'newMappings': 0, 'published': False})
                retain_effective_retry(conn, source)
        from epg_source_recovery import run as recover_sources
        managed = [source_for(row[0]) for row in conn.execute(
            'SELECT country FROM epg_source_discovery_jobs WHERE active=1')]
        recovery = recover_sources(conn, list(configured) + managed, channels, now)
        result = {'schemaVersion': 1, 'stage': 'bounded_provider_discovery', 'checkedAtUtc': now,
            'catalogVersion': manifest['version'], 'attemptedSources': int(due is not None),
            'selectedSourceId': selected, 'safeError': error, 'providerRetryAtUtc': provider_retry,
            'activeJobs': conn.execute('SELECT count(*) FROM epg_source_discovery_jobs WHERE active=1').fetchone()[0],
            'jobStates': dict(conn.execute('SELECT state,count(*) FROM epg_source_discovery_jobs WHERE active=1 GROUP BY state').fetchall()),
            'supportedProviderCount': 1, 'sourceRecovery': recovery,
            'automaticMappingApproval': False, 'published': False}
        with conn:
            conn.execute('INSERT OR REPLACE INTO epg_checkpoints VALUES(?,?)', ('source_discovery', json.dumps(result)))
        return result
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir', type=Path, default=Path(DATA))
    args = parser.parse_args()
    directory = args.data_dir / 'epg'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / 'worker.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(json.dumps({'state': 'already_running'}))
            return
        manifest, channels = load_catalog(args.data_dir)
        print(json.dumps(run(directory, manifest, channels, registry())))


if __name__ == '__main__':
    main()
