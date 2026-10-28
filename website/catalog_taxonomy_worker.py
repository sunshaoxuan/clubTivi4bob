"""Small resumable AI batches for pending geography and radio/TV classification."""
import fcntl
import hashlib
import json
import re
import time
from datetime import datetime, timezone
from pathlib import Path

from catalog_inventory import database
from catalog_taxonomy import apply_channel_paths, classified_path
from country_names import _DATA
import reclassify_public_catalog as audit
from publish_channel_catalog import publish, _atomic_write
from server_jobs import DATA
from server_worker import BudgetDeferred, error_code, write_state


def eligible_targets(targets, previous, now):
    def due(item):
        record = previous.get(item['key'])
        return not record or (record.get('status') != 'classified' and now - record.get('time', 0) >= 7 * 86400)
    eligible = [item for item in targets if not item['manualOnly'] and item['routeDigests'] and due(item)]
    def priority(item):
        pending = item['currentPath'][0] == '其他'
        radio_hint = bool(re.search(r'广播|電台|电台|\bradio\b|\bfm\b|\bam\b', item['name'], re.I))
        return (not pending, not radio_hint, item['key'])
    return sorted(eligible, key=priority)


def run(data_dir=DATA):
    data_dir = Path(data_dir)
    folder = data_dir / 'taxonomy-classification'
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / 'worker.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {'state': 'already_running'}
        now = int(time.time())
        status_path = folder / 'status.json'
        try:
            previous_status = json.loads(status_path.read_text())
        except (OSError, ValueError):
            previous_status = {}
        if previous_status.get('nextAttempt', 0) > now:
            return previous_status
        log = folder / 'decisions.jsonl'
        previous = {}
        if log.exists():
            for line in log.read_text().splitlines():
                try:
                    record = json.loads(line)
                    previous[record['key']] = record
                except (ValueError, KeyError):
                    continue
        _, targets = audit.collect_targets(data_dir)
        queue = eligible_targets(targets, previous, now)
        if not queue:
            status = {'state': 'idle', 'pending': 0, 'time': now}
            write_state(folder / 'status.json', status)
            return status
        batch = queue[:audit.BATCH_SIZE]
        with database(data_dir) as conn:
            expected = {row['digest']: (row['revision'], row['group_name']) for row in conn.execute(
                'SELECT digest,revision,group_name FROM routes WHERE blocked=0 AND deleted=0 AND manual_category=0')}
        # Reuse the configured endpoint/model; only the upstream controls availability.
        audit.ALLOWED_COUNTRIES.update(set(_DATA['names'].values()) - {'中国'})
        try:
            results = audit.classify_batch(batch, audit.audit_settings(), data_dir)
        except Exception as exc:
            code, delay = audit.upstream_retry(exc, 1)
            status = {'state': 'retry_pending' if delay is not None else 'requires_attention',
                      'error': code, 'pending': len(queue), 'time': now}
            if delay is not None:
                status['nextAttempt'] = now + max(1, int(delay))
            write_state(folder / 'status.json', status)
            return status
        changes = {}
        for result in results:
            result['time'] = now
            if result['status'] == 'classified':
                result['newPath'] = classified_path(result['newPath'], {})
        with (data_dir / 'catalog-process.lock').open('a') as publication_lock:
            fcntl.flock(publication_lock, fcntl.LOCK_EX)
            manifest, payload, _ = audit.load_catalog(data_dir)
            _, fresh = audit.collect_targets(data_dir)
            by_key = {item['key']: item for item in fresh}
            channels_by_digest = {hashlib.sha256(route['url'].encode()).hexdigest(): channel['id']
                for channel in payload['channels'] for route in channel['routes']}
            with database(data_dir) as conn:
                conn.execute('BEGIN IMMEDIATE')
                backups = []
                for result in results:
                    current = by_key.get(result['key'])
                    if result['status'] != 'classified' or not current:
                        continue
                    if current['currentPath'] != result['oldPath'] or current['manualCount']:
                        result['status'] = 'changed_during_review'
                        continue
                    rows = [conn.execute('SELECT * FROM routes WHERE digest=?', (digest,)).fetchone()
                            for digest in result['routeDigests']]
                    if not rows or any(not row or row['manual_category'] or row['blocked'] or row['deleted']
                        or (row['revision'], row['group_name']) != expected.get(row['digest']) for row in rows):
                        result['status'] = 'changed_during_review'
                        continue
                    identities = {channels_by_digest.get(digest) for digest in result['routeDigests']}
                    channel_id = next(iter(identities)) if len(identities) == 1 else None
                    if channel_id is None:
                        result['status'] = 'changed_during_review'
                        continue
                    changes[channel_id] = result['newPath']
                    group = ' / '.join(result['newPath'])
                    for row in rows:
                        backups.append({'digest': row['digest'], 'group': row['group_name'], 'revision': row['revision']})
                        if row['group_name'] != group:
                            conn.execute('UPDATE routes SET group_name=?,revision=revision+1 WHERE digest=?', (group,row['digest']))
                if changes:
                    backup = folder / ('backup-' + str(time.time_ns()))
                    backup.mkdir()
                    manifest_path = data_dir / 'channel-catalog' / 'manifest.json'
                    old_manifest = manifest_path.read_bytes()
                    (backup / 'manifest.json').write_bytes(old_manifest)
                    (backup / 'route-groups.json').write_text(json.dumps(backups, ensure_ascii=False))
                    updated = apply_channel_paths(payload, changes)
                    updated['version'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%fZ')
                    try:
                        publish(updated, data_dir)
                        conn.commit()
                    except BaseException:
                        _atomic_write(manifest_path, old_manifest)
                        raise
        with log.open('a') as output:
            for record in results:
                output.write(json.dumps(record, ensure_ascii=False) + '\n')
        status = {'state': 'running', 'time': now, 'reviewed': len(results), 'applied': len(changes),
                  'needsReview': sum(item['status'] != 'classified' for item in results),
                  'pending': max(0,len(queue)-len(results)), 'model': audit.audit_settings().get('model')}
        write_state(folder / 'status.json', status)
        return status


if __name__ == '__main__':
    print(json.dumps(run(), ensure_ascii=False))
