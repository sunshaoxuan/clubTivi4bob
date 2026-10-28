"""One-channel durable research scheduler; search execution is still unavailable.

Replaces the country-provider discovery entry point without fetching providers.
Existing validated source refresh, player mappings and programme stores are not
modified. Incomplete channel identity is explicitly parked for review.
"""
import argparse
import fcntl
import gzip
import hashlib
import io
import json
from pathlib import Path
import sqlite3
import time

from catalog_inventory import DATA
from epg_discovery import load_catalog, priority
from epg_ingest import EpgError, database
import epg_channel_research as queue


def load_targets(data_dir):
    manifest, channels = load_catalog(data_dir)
    path = Path(data_dir) / 'channel-catalog' / 'snapshots' / (manifest['sha256'] + '.json.gz')
    if path.stat().st_size > 32 * 1024 * 1024:
        raise EpgError('catalog_compressed_limit')
    compressed = path.read_bytes()
    if hashlib.sha256(compressed).hexdigest() != manifest['sha256']:
        raise EpgError('catalog_checksum_mismatch')
    with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as handle:
        raw = handle.read(64 * 1024 * 1024 + 1)
    if len(raw) > 64 * 1024 * 1024:
        raise EpgError('catalog_decoded_limit')
    # Verify the same decoded document again: the immutable file must not change
    # between the loader and category read, including channel/route mutations.
    document = json.loads(raw)
    if document.get('version') != manifest['version'] or document.get('channels') != channels:
        raise EpgError('research_catalog_changed')
    categories = {item['id']: item for item in document.get('categories', [])}
    paths = {}
    for channel in channels:
        current, names, seen = channel.get('categoryId'), [], set()
        while current:
            if current in seen or current not in categories or len(seen) >= 8:
                raise EpgError('invalid_research_category')
            seen.add(current)
            category = categories[current]
            names.insert(0, category['name'])
            current = category.get('parentId')
        if not names:
            raise EpgError('invalid_research_category')
        paths[channel['id']] = names
    return manifest, channels, paths


def protected_ids(conn):
    if not conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='epg_mapping_approvals'").fetchone():
        return set()
    # Preserve even a temporarily invalid approval: discovery has no authority
    # to revoke an operator's mapping or to replace its source.
    return {r[0] for r in conn.execute('SELECT channel_id FROM epg_mapping_approvals WHERE revoked=0')}


def peek_due(conn, now, channel_id=None):
    """Select a due case without leasing or advancing a real review deadline.

    This scheduler has no network executor yet. A timer observation must not
    consume an attempt or continuously postpone an operator's actual review.
    Real execution continues to use the queue's guarded claim API.
    """
    return conn.execute('''SELECT * FROM epg_channel_research_jobs
      WHERE active=1 AND next_retry<=? AND lease_until<=? AND (? IS NULL OR channel_id=?)
      ORDER BY priority,next_retry,channel_id LIMIT 1''',
      (now, now, channel_id, channel_id)).fetchone()


def run(directory, manifest, channels, category_paths, now=None, *, focus_channel=None, preferred_channel=None):
    now = int(time.time() if now is None else now)
    if not isinstance(channels, list) or len(channels) > 10000 or len({c['id'] for c in channels}) != len(channels):
        raise EpgError('invalid_research_catalog')
    by_id = {c['id']: c for c in channels}
    if focus_channel is not None and preferred_channel is not None:
        raise EpgError('conflicting_research_selection_modes')
    if focus_channel is not None and focus_channel not in by_id:
        raise EpgError('research_focus_missing')
    if preferred_channel is not None and preferred_channel not in by_id:
        raise EpgError('research_preferred_missing')
    conn = database(directory)
    try:
        queue.migrate(conn)
        conn.execute('CREATE TABLE IF NOT EXISTS epg_checkpoints(name TEXT PRIMARY KEY,value TEXT NOT NULL)')
        protected = protected_ids(conn)
        # Refresh only previously selected tasks. No bulk source list or reverse
        # provider-to-catalogue match is used for target selection.
        existing = conn.execute('SELECT channel_id FROM epg_channel_research_jobs').fetchall()
        for item in existing:
            identity = item['channel_id']
            if identity not in by_id:
                queue.deactivate(conn,identity,now,'catalog_channel_removed')
            else:
                queue.enqueue(conn,by_id[identity],manifest['version'],category_paths[identity],now,
                              protected=identity in protected)
        explicit = focus_channel if focus_channel is not None else preferred_channel
        if explicit is not None:
            selected = by_id[explicit]
            queue.enqueue(conn,selected,manifest['version'],category_paths[explicit],now,
                          protected=explicit in protected)
        else:
            known = {r[0] for r in conn.execute('SELECT channel_id FROM epg_channel_research_jobs')}
            selected = next((c for c in sorted(channels,key=lambda c:(priority(c),c['id']))
                             if c['id'] not in known and c['id'] not in protected), None)
            if selected is not None:
                queue.enqueue(conn,selected,manifest['version'],category_paths[selected['id']],now)
        due = peek_due(conn,now,channel_id=focus_channel if focus_channel is not None else preferred_channel)
        if preferred_channel is not None and due is None:
            # Only already selected, active and due cases may rotate. The
            # preferred target's cooldown is not shortened, and no unrelated
            # catalogue channel is enqueued in this mode.
            due = peek_due(conn,now)
        execution_error = None
        if due is not None:
            execution_error = 'search_executor_unavailable' if due['identity_evidence'] else 'identity_review_required'
        current_id = focus_channel or (due['channel_id'] if due else selected['id'] if selected else None)
        row = conn.execute('SELECT * FROM epg_channel_research_jobs WHERE channel_id=?',(current_id,)).fetchone()
        result = {'schemaVersion':1,'stage':'channel_first_identity_gate','checkedAtUtc':now,
            'catalogVersion':manifest['version'],'catalogChannels':len(channels),
            'selectedChannelId':current_id,
            'selectedChannelName':by_id[current_id]['name'] if current_id else None,
            'selectedCategoryPath':category_paths.get(current_id),
            'identityReviewed':bool(row and row['identity_evidence']),
            'state':row['state'] if row and row['active'] else 'protected_mapping' if current_id in protected else 'idle',
            'safeError':(row['last_error'] or execution_error) if row and row['active'] else None,
            'executionSafeError':execution_error,
            'nextRetryAtUtc':row['next_retry'] if row and row['active'] else None,
            'selectionMode':'known_queue_preferred_then_due' if preferred_channel is not None else 'strict_focus' if focus_channel is not None else 'select_one_catalogue_target',
            'preferredChannelId':preferred_channel,'knownQueueOnly':preferred_channel is not None,
            'claimedChannels':0,'selectedDueChannels':int(due is not None),
            'readOnlyDueSelection':True,'retryFloorsAdvancedWithoutExecution':False,
            'activeJobs':conn.execute(
                'SELECT count(*) FROM epg_channel_research_jobs WHERE active=1').fetchone()[0],
            'legacyCountryProviderDiscoveryEnabled':False,'networkSearchExecutorImplemented':False,
            'sourceNetworkRequests':0,'newMappings':0,'newGrants':0,'published':False}
        with conn:
            conn.execute('INSERT OR REPLACE INTO epg_checkpoints VALUES(?,?)',('channel_research',json.dumps(result)))
        return result
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir',type=Path,default=Path(DATA))
    parser.add_argument('--focus-channel')
    parser.add_argument('--preferred-channel')
    args = parser.parse_args()
    directory = args.data_dir / 'epg'
    directory.mkdir(parents=True,exist_ok=True,mode=0o700)
    with (directory / 'worker.lock').open('a') as lock:
        try:
            fcntl.flock(lock,fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(json.dumps({'state':'already_running'}))
            return
        try:
            manifest, channels, paths = load_targets(args.data_dir)
            print(json.dumps(run(directory,manifest,channels,paths,focus_channel=args.focus_channel,
                                 preferred_channel=args.preferred_channel)))
        except sqlite3.OperationalError as exc:
            if 'locked' not in str(exc).lower() and 'busy' not in str(exc).lower():
                raise
            print(json.dumps({'state':'deferred','safeError':'database_busy','sourceNetworkRequests':0}))


if __name__ == '__main__':
    main()
