"""Bounded disk inbox for temporary catalogue writer contention.

The inbox never claims an edit was applied. Legacy clients receive retry
receipts and retain their outbox until the canonical inventory commits it.
"""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import time

MAX_BYTES = 64 * 1024 * 1024
MAX_JOBS = 2048


@contextmanager
def database(root):
    folder = Path(root) / 'catalog-event-inbox'
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = folder / 'queue.sqlite3'
    conn = sqlite3.connect(path, timeout=1)
    os.chmod(path, 0o600)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute('PRAGMA journal_mode=WAL')
        conn.execute('CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, body BLOB NOT NULL, received INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_retry INTEGER NOT NULL DEFAULT 0)')
        with conn:
            yield conn
    finally:
        conn.close()


def enqueue(root, payload, now=None):
    from catalog_inventory import validate_media_url
    from fastapi import HTTPException
    import re
    for event in payload['events']:
        if not isinstance(event, dict) or not re.fullmatch(r'[a-f0-9-]{16,80}', str(event.get('id', ''))):
            raise HTTPException(422, 'Invalid event ID')
        validate_media_url(event.get('url'))
        if event.get('kind') not in {'merge', 'transfer', 'health', 'retire', 'delete', 'classify', 'upsert'}:
            raise HTTPException(422, 'Invalid event kind')
    body = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
    if len(body) > 512 * 1024:
        raise HTTPException(413, 'Sync batch exceeds byte limit')
    digest = hashlib.sha256(body).hexdigest()
    now = int(time.time()) if now is None else now
    with database(root) as conn:
        conn.execute('BEGIN IMMEDIATE')
        conn.execute('DELETE FROM jobs WHERE received<?', (now - 7 * 86400,))
        if not conn.execute('SELECT 1 FROM jobs WHERE id=?', (digest,)).fetchone():
            count, size = conn.execute('SELECT count(*),coalesce(sum(length(body)),0) FROM jobs').fetchone()
            if count >= MAX_JOBS or size + len(body) > MAX_BYTES:
                raise HTTPException(429, 'Sync inbox temporarily full', headers={'Retry-After': '60'})
            conn.execute('INSERT INTO jobs(id,body,received) VALUES(?,?,?)', (digest, body, now))
    return {'schemaVersion': 1, 'queued': True,
            'receipts': [{'id': e['id'], 'status': 'retry', 'revision': 0} for e in payload['events']]}


def drain(root, now=None):
    from catalog_inventory import ingest_events, _publish_changes
    from fastapi import HTTPException
    now = int(time.time()) if now is None else now
    with database(root) as conn:
        conn.execute('DELETE FROM jobs WHERE received<?', (now - 7 * 86400,))
        jobs = [dict(row) for row in conn.execute('SELECT * FROM jobs WHERE next_retry<=? ORDER BY received,id LIMIT 5', (now,))]
    processed = deferred = 0
    for job in jobs:
        try:
            payload = json.loads(job['body'])
            ingest_events(payload['events'], payload['fingerprint'], root, busy_timeout=1)
        except (sqlite3.OperationalError, HTTPException) as error:
            if isinstance(error, HTTPException) and error.status_code in (413, 422):
                # Invalid work cannot block valid following jobs. Clients still
                # retain the original event and receive validation on retry.
                with database(root) as conn:
                    conn.execute('DELETE FROM jobs WHERE id=?', (job['id'],))
                continue
            with database(root) as conn:
                conn.execute('UPDATE jobs SET attempts=attempts+1,next_retry=? WHERE id=?',
                             (now + min(3600, 15 * 2 ** min(job['attempts'], 8)), job['id']))
            deferred += 1
            continue
        with database(root) as conn:
            conn.execute('DELETE FROM jobs WHERE id=?', (job['id'],))
        processed += 1
    if processed:
        _publish_changes()
    return {'processed': processed, 'deferred': deferred}

