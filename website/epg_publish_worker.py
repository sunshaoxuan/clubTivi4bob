"""Independent bounded publisher for already permitted, exactly mapped EPG.

Only the two fixed BobTV nodes are contacted by epg_store.publish. This worker
never creates data grants, mappings or programmes, and never fetches upstream
EPG sources. The authoritative activation pointer remains in the primary DB.
"""
import argparse
import fcntl
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
    code = str(error) if isinstance(error, EpgError) else 'publication_worker_failure'
    known = {'no_publishable_current_future_data', 'public_snapshot_unavailable',
        'public_snapshot_checksum_mismatch', 'public_snapshot_content_mismatch',
        'approval_changed_during_publication', 'data_changed_during_publication',
        'publication_decoded_limit', 'publication_compressed_limit', 'publication_size_limit',
        'invalid_publication_receipt', 'fetch_deadline', 'compressed_size_limit',
        'unreviewed_redirect', 'redirect_limit'}
    return code if code in known or re.fullmatch(r'http_[1-5][0-9]{2}', code) else 'publication_worker_failure'


def migrate(conn):
    discovery.migrate(conn)
    store.migrate(conn)
    conn.execute('''CREATE TABLE IF NOT EXISTS epg_publisher_attempts (
      id INTEGER PRIMARY KEY, started_at INTEGER NOT NULL, finished_at INTEGER,
      state TEXT NOT NULL, error_code TEXT, version TEXT, sha256 TEXT,
      next_retry INTEGER NOT NULL DEFAULT 0)''')
    conn.commit()


def previous_checkpoint(conn):
    row = conn.execute("SELECT value FROM epg_checkpoints WHERE name='publisher'").fetchone()
    if row is None:
        return {'failures': 0, 'nextRetryAt': 0}
    try:
        value = json.loads(row[0])
        if (not isinstance(value, dict) or type(value.get('failures')) is not int
                or not 0 <= value['failures'] <= 1000000
                or type(value.get('nextRetryAt')) is not int or value['nextRetryAt'] < 0):
            raise ValueError('invalid checkpoint')
        return value
    except (ValueError, TypeError):
        raise EpgError('publisher_checkpoint_invalid') from None


def active_metadata(conn, now):
    try:
        active = store.active_manifest(conn)
    except EpgError:
        return {'activeVersion': None, 'activationUnavailable': True}
    return {'activeVersion': active['version'] if active else None,
        'lastPublishedChannelCount': active['channelCount'] if active else 0,
        'activeCoverageExpired': bool(active and active['coverageEndUtc'] <= now)}


def run(directory, *, now=None, node_fetcher=None):
    live_clock = now is None
    now = int(time.time() if now is None else now)
    directory = Path(directory)
    outcome = {'schemaVersion': 1, 'stage': 'epg_publication', 'checkedAtUtc': now,
        'state': 'waiting_for_database', 'published': False, 'error': None}
    if not (directory / 'epg.sqlite3').is_file():
        return outcome
    with (directory / 'publisher-worker.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {**outcome, 'state': 'waiting_for_lock'}
        conn = database(directory)
        try:
            migrate(conn)
            previous = previous_checkpoint(conn)
            outcome.update({'failures': previous['failures'], 'nextRetryAt': previous['nextRetryAt']})
            if previous['nextRetryAt'] > now:
                outcome.update({'state': 'waiting_for_retry', **active_metadata(conn, now)})
                # Preserve the attempt's outcome and durable retry deadline.
                return outcome
            with conn:
                conn.execute("UPDATE epg_publisher_attempts SET finished_at=?,state='interrupted',error_code='worker_interrupted' WHERE state='publishing' AND finished_at IS NULL", (now,))
                attempt = conn.execute("INSERT INTO epg_publisher_attempts(started_at,state,next_retry) VALUES(?,'publishing',?)", (now, now + 120)).lastrowid
                in_flight = {**outcome, 'state': 'publishing', 'nextRetryAt': now + 120, 'attemptId': attempt}
                conn.execute('INSERT OR REPLACE INTO epg_checkpoints VALUES(?,?)', ('publisher', json.dumps(in_flight)))
            node_error, retry_after = None, 0
            def read_node(url):
                nonlocal node_error, retry_after
                try:
                    return (node_fetcher or store._node_fetch)(url)
                except (EpgError, OSError, ValueError) as error:
                    node_error = safe_error(error)
                    if isinstance(error, EpgError):
                        retry_after = max(retry_after, error.retry_after)
                    raise
            try:
                published = store.publish(conn, directory / 'public', now=None if live_clock else now, node_fetcher=read_node)
                outcome.update({'state': 'published' if published['changed'] else 'unchanged',
                    'published': published['changed'], 'version': published['version'],
                    'sha256': published['sha256'], 'failures': 0, 'nextRetryAt': 0})
            except BlockingIOError:
                outcome.update({'state': 'waiting_for_lock', 'nextRetryAt': now + 60})
            except (EpgError, OSError, ValueError, sqlite3.Error) as error:
                code = node_error or safe_error(error)
                if code == 'no_publishable_current_future_data':
                    outcome.update({'state': 'waiting_for_approved_programmes', 'failures': 0,
                        'nextRetryAt': 0, 'error': code})
                else:
                    failures = min(1000000, previous['failures'] + 1)
                    delay = max(min(21600, 60 * 2 ** min(failures - 1, 9)), retry_after)
                    outcome.update({'state': 'failed', 'failures': failures,
                        'nextRetryAt': now + delay, 'error': code})
            outcome.update({'attemptId': attempt, **active_metadata(conn, now)})
            with conn:
                conn.execute('UPDATE epg_publisher_attempts SET finished_at=?,state=?,error_code=?,version=?,sha256=?,next_retry=? WHERE id=?',
                    (now, outcome['state'], outcome['error'], outcome.get('version'), outcome.get('sha256'), outcome['nextRetryAt'], attempt))
                conn.execute('INSERT OR REPLACE INTO epg_checkpoints VALUES(?,?)', ('publisher', json.dumps(outcome)))
            return outcome
        finally:
            conn.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir', type=Path, default=Path(DATA) / 'epg')
    args = parser.parse_args()
    print(json.dumps(run(args.data_dir)))


if __name__ == '__main__':
    main()
