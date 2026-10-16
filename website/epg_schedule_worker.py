"""Bounded licensed programme ingestion; publication is explicitly enabled later.

No upstream fetches here. The existing serial validator hands off only approved
data through a private checksummed cache. No grants or mappings are created.
"""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import time

from catalog_inventory import DATA
import epg_discovery as discovery
from epg_ingest import EpgError, database
import epg_store as store


def safe_error(error):
    code = str(error) if isinstance(error, EpgError) else 'programme_worker_failure'
    return code if re.fullmatch(r'[a-z0-9_]{1,80}', code) else 'programme_worker_failure'


def due_jobs(conn, now, batch_size):
    selected, waiting, blocked = [], 0, 0
    for candidate in conn.execute('''SELECT a.channel_id FROM epg_mapping_approvals a
      JOIN discovery_jobs j ON j.channel_id=a.channel_id AND j.active=1
      WHERE a.revoked=0 ORDER BY j.priority,j.channel_id''').fetchall():
        try:
            approved = dict(store._approved(conn, candidate['channel_id']))
        except EpgError:
            blocked += 1
            continue
        cached = conn.execute('SELECT * FROM epg_source_payloads WHERE source_id=?', (approved['source_id'],)).fetchone()
        if not cached:
            waiting += 1
            continue
        credit = conn.execute('SELECT metadata FROM epg_data_attributions WHERE source_id=?', (approved['source_id'],)).fetchone()
        digest = discovery.fingerprint([approved, dict(cached), credit[0] if credit else None])
        old = conn.execute('SELECT * FROM epg_ingestion_jobs WHERE channel_id=?', (approved['channel_id'],)).fetchone()
        if old and old['input_hash'] == digest and (old['state'] == 'complete' or old['next_retry'] > now):
            continue
        if selected and approved['source_id'] != selected[0]['source_id']:
            continue
        if len(selected) >= batch_size:
            continue
        with conn:
            conn.execute('''INSERT INTO epg_ingestion_jobs VALUES(?,?,?,0,0,?,NULL)
              ON CONFLICT(channel_id) DO UPDATE SET input_hash=excluded.input_hash,
              state=CASE WHEN input_hash!=excluded.input_hash THEN 'pending' ELSE state END,
              attempts=CASE WHEN input_hash!=excluded.input_hash THEN 0 ELSE attempts END,
              next_retry=CASE WHEN input_hash!=excluded.input_hash THEN 0 ELSE next_retry END''',
                (approved['channel_id'], digest, 'pending', now))
        selected.append({'channel_id': approved['channel_id'], 'source_id': approved['source_id'],
                         'input_hash': digest, 'cached': dict(cached)})
    return selected, waiting, blocked


def read_payload(conn, directory, job, now):
    cached = job['cached']
    source_id = job['source_id']
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,79}', source_id) or cached['file_name'] != source_id + '.bin':
        raise EpgError('unsafe_payload_cache_path')
    path = Path(directory) / 'payload-cache' / cached['file_name']
    if path.is_symlink() or path.parent.is_symlink() or not path.is_file() or path.stat().st_size > 8 * 1024 * 1024:
        raise EpgError('payload_cache_unavailable')
    with path.open('rb') as stream:
        body = stream.read(8 * 1024 * 1024 + 1)
    if not body or len(body) > 8 * 1024 * 1024 or hashlib.sha256(body).hexdigest() != cached['sha256']:
        raise EpgError('payload_cache_checksum_mismatch')
    source = conn.execute('SELECT * FROM source_health WHERE id=?', (source_id,)).fetchone()
    if (not source or source['state'] == 'superseded' or source['last_success'] != cached['fetched_at']
            or source['content_sha256'] != cached['sha256']):
        raise EpgError('fetch_provenance_mismatch')
    if now - cached['fetched_at'] > json.loads(source['configuration'])['refreshSeconds'] * 2:
        raise EpgError('payload_cache_expired')
    return body


def coverage(conn, now):
    from epg_coverage import summarize
    result = summarize(conn, now)
    return {key: result[key] for key in ('catalogChannels', 'verifiedMappings', 'currentAndFutureChannels')}


def _run(directory, now, batch_size, enable_publication, node_fetcher):
    conn = database(directory)
    try:
        discovery.migrate(conn)
        store.migrate(conn)
        jobs, waiting, blocked = due_jobs(conn, now, batch_size)
        outcome = {'schemaVersion': 1, 'stage': 'programme_ingestion', 'checkedAtUtc': now,
            'selectedChannels': len(jobs), 'changedChannels': 0, 'retainedChannels': 0,
            'failedChannels': 0, 'waitingForApprovedPayload': waiting, 'blockedApprovals': blocked,
            'publicationEnabled': enable_publication, 'published': False, 'error': None}
        if jobs:
            # Commit leases before parsing so killed tasks back off on resume.
            with conn:
                for job in jobs:
                    conn.execute("UPDATE epg_ingestion_jobs SET state='processing',attempts=attempts+1,next_retry=?,checked_at=? WHERE channel_id=?",
                        (now + 120, now, job['channel_id']))
            try:
                body = read_payload(conn, directory, jobs[0], now)
                rows = store.ingest_batch(conn, jobs[0]['source_id'], body,
                    [j['channel_id'] for j in jobs], fetched_at=jobs[0]['cached']['fetched_at'], now=now)
                with conn:
                    for row in rows:
                        retained = row['retainedLastGood']
                        outcome['changedChannels'] += int(row['changed'])
                        outcome['retainedChannels'] += int(retained)
                        conn.execute('UPDATE epg_ingestion_jobs SET state=?,next_retry=?,checked_at=?,last_error=? WHERE channel_id=?',
                            ('waiting_coverage' if retained else 'complete', now + 900 if retained else 0,
                             now, 'insufficient_current_future_coverage' if retained else None, row['channelId']))
            except (EpgError, OSError, ValueError, sqlite3.Error) as error:
                outcome['error'] = safe_error(error)
                outcome['failedChannels'] = len(jobs)
                with conn:
                    for job in jobs:
                        attempts = conn.execute('SELECT attempts FROM epg_ingestion_jobs WHERE channel_id=?', (job['channel_id'],)).fetchone()[0]
                        delay = min(21600, 60 * 2 ** min(attempts - 1, 9))
                        conn.execute("UPDATE epg_ingestion_jobs SET state='failed',next_retry=?,last_error=? WHERE channel_id=?",
                            (now + delay, outcome['error'], job['channel_id']))
        if enable_publication:
            previous = conn.execute("SELECT value FROM epg_checkpoints WHERE name='publication_retry'").fetchone()
            retry = json.loads(previous[0]) if previous else {'failures': 0, 'nextRetryAt': 0}
            if retry['nextRetryAt'] <= now:
                try:
                    kwargs = {'now': now}
                    if node_fetcher is not None:
                        kwargs['node_fetcher'] = node_fetcher
                    published = store.publish(conn, Path(directory) / 'public', **kwargs)
                    outcome['published'] = published['changed']
                    outcome['publishedVersion'] = published['version']
                    retry = {'failures': 0, 'nextRetryAt': 0}
                except (EpgError, OSError, ValueError, sqlite3.Error) as error:
                    retry['failures'] += 1
                    delay = min(21600, 60 * 2 ** min(retry['failures'] - 1, 9))
                    retry['nextRetryAt'] = now + max(delay, error.retry_after if isinstance(error, EpgError) else 0)
                    outcome['publicationError'] = safe_error(error)
                with conn:
                    conn.execute('INSERT OR REPLACE INTO epg_checkpoints VALUES(?,?)',
                        ('publication_retry', json.dumps(retry)))
            outcome['publicationNextRetryAt'] = retry['nextRetryAt']
        outcome['coverage'] = coverage(conn, now)
        previous = conn.execute("SELECT value FROM epg_checkpoints WHERE name='programme_ingestion'").fetchone()
        before_coverage = json.loads(previous[0]).get('coverage', {}) if previous else {}
        outcome['coverageDeclined'] = outcome['coverage']['currentAndFutureChannels'] < before_coverage.get('currentAndFutureChannels', 0)
        with conn:
            conn.execute('INSERT OR REPLACE INTO epg_checkpoints VALUES(?,?)',
                ('programme_ingestion', json.dumps(outcome)))
        return outcome
    finally:
        conn.close()


def run(directory, *, now=None, batch_size=5, enable_publication=False, node_fetcher=None):
    if type(batch_size) is not int or not 1 <= batch_size <= 5:
        raise EpgError('batch_size_limit')
    now = int(time.time() if now is None else now)
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Shared with the existing source validator: no duplicate fetch/parse work.
    with (directory / 'worker.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {'stage': 'programme_ingestion', 'state': 'already_running'}
        return _run(directory, now, batch_size, enable_publication, node_fetcher)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir', type=Path, default=Path(DATA) / 'epg')
    parser.add_argument('--enable-publication', action='store_true')
    args = parser.parse_args()
    print(json.dumps(run(args.data_dir, enable_publication=args.enable_publication)))


if __name__ == '__main__':
    main()
