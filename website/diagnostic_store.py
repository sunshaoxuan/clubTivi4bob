"""Private, bounded diagnostic batches and durable relay receipts.

Only an allowlisted structured projection enters this store. No public body
download exists. A content digest is an opaque receipt, never an authorization
to fetch the payload. Both the origin and relay expire data by event age.
"""
import hashlib
import json
import math
import os
import re
import sqlite3
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

MAX_BODY = 256 * 1024
MAX_ENTRIES = 500
RETENTION = 30 * 86400
MAX_STORAGE = 512 * 1024 * 1024
TAG = re.compile(r'^[A-Za-z][A-Za-z0-9_]{0,79}$')
VERSION = re.compile(r'^\d{1,4}\.\d{1,4}\.\d{1,4}\+\d{1,8}$')
ID = re.compile(r'^[a-f0-9]{64}$')
FIELDS = {'time', 'event', 'source', 'fatal', 'uptimeSeconds', 'rssBytes',
          'maxRssBytes', 'platform', 'appVersion', 'phase', 'node', 'endpoint',
          'errorCode', 'httpStatus', 'elapsedMs', 'bytes', 'attempt', 'requestId'}
ENUMS = {
    'platform': {'android', 'windows', 'macos', 'linux', 'ios'},
    'phase': {'open', 'headers', 'body', 'complete', 'retry'},
    'node': {'origin', 'cndrp', 'local'},
    'endpoint': {'catalog_manifest', 'catalog_snapshot', 'catalog_blocked',
                 'catalog_events', 'catalog_inventory', 'route_state',
                 'network_profile', 'route_rank', 'epg_manifest', 'epg_snapshot',
                 'diagnostics', 'favorites', 'other_api'},
    'errorCode': {'timeout', 'socket', 'tls', 'http', 'format', 'cancelled',
                  'server_busy', 'other'},
}


class StoreLimit(Exception):
    pass


def validate_batch(body, now=None):
    now = time.time() if now is None else now
    if not 1 <= len(body) <= MAX_BODY:
        raise ValueError('Diagnostic batch exceeds byte limit')
    value = json.loads(body)
    if (not isinstance(value, dict) or set(value) != {'schemaVersion', 'consentVersion', 'installationId', 'entries'}
            or value['schemaVersion'] != 2 or value['consentVersion'] != 2
            or not isinstance(value['installationId'], str)
            or not re.fullmatch(r'[a-f0-9]{32}', value['installationId'])):
        raise ValueError('Invalid diagnostic envelope')
    entries = value['entries']
    if not isinstance(entries, list) or not 1 <= len(entries) <= MAX_ENTRIES:
        raise ValueError('Invalid diagnostic entry count')
    oldest = now
    for entry in entries:
        if not isinstance(entry, dict) or not {'time', 'event'} <= entry.keys() or not entry.keys() <= FIELDS:
            raise ValueError('Unexpected diagnostic fields')
        for key, item in entry.items():
            if key == 'time':
                if not isinstance(item, str) or len(item) > 40 or not item.endswith('Z'):
                    raise ValueError('UTC diagnostic timestamp required')
                stamp = datetime.fromisoformat(item[:-1] + '+00:00').timestamp()
                if not now - RETENTION < stamp <= now + 300:
                    raise ValueError('Diagnostic timestamp outside retention')
                oldest = min(oldest, stamp)
            elif key in ENUMS:
                if not isinstance(item, str) or item not in ENUMS[key]:
                    raise ValueError('Invalid diagnostic enum')
            elif key == 'appVersion':
                if not isinstance(item, str) or not VERSION.fullmatch(item):
                    raise ValueError('Invalid application version')
            elif key in {'event', 'source'}:
                if not isinstance(item, str) or not TAG.fullmatch(item):
                    raise ValueError('Invalid diagnostic tag')
            elif key == 'requestId':
                if not isinstance(item, str) or not re.fullmatch(r'[a-f0-9]{32}', item):
                    raise ValueError('Invalid request ID')
            elif key == 'fatal':
                if type(item) is not bool:
                    raise ValueError('Invalid diagnostic flag')
            elif type(item) not in (int, float) or not math.isfinite(item) or not 0 <= item <= 10**15:
                raise ValueError('Invalid diagnostic metric')
            elif key == 'httpStatus' and (type(item) is not int or not 100 <= item <= 599):
                raise ValueError('Invalid HTTP status')
    return value, int(oldest + RETENTION)


class DiagnosticStore:
    def __init__(self, directory, *, maximum=MAX_STORAGE, state='origin_accepted'):
        self.directory = Path(directory)
        self.maximum = maximum
        self.initial_state = state

    @contextmanager
    def database(self):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.directory, 0o700)
        path = self.directory / 'batches.sqlite3'
        conn = sqlite3.connect(path, timeout=2)
        os.chmod(path, 0o600)
        conn.row_factory = sqlite3.Row
        try:
            conn.execute('PRAGMA journal_mode=WAL')
            conn.execute('PRAGMA secure_delete=ON')
            conn.execute('CREATE TABLE IF NOT EXISTS batches (id TEXT PRIMARY KEY, body BLOB, installation TEXT NOT NULL, received INTEGER NOT NULL, expires INTEGER NOT NULL, state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_retry INTEGER NOT NULL DEFAULT 0)')
            conn.execute('CREATE INDEX IF NOT EXISTS diagnostic_expiry ON batches(expires)')
            conn.execute('CREATE TABLE IF NOT EXISTS limits (key TEXT NOT NULL, hour INTEGER NOT NULL, count INTEGER NOT NULL, PRIMARY KEY(key,hour))')
            with conn:
                yield conn
        finally:
            conn.close()

    @staticmethod
    def prune_conn(conn, now):
        conn.execute('DELETE FROM batches WHERE expires<=?', (now,))
        conn.execute('DELETE FROM limits WHERE hour<?', (now // 3600 - 24,))

    def put(self, body, *, quota='', now=None):
        now = int(time.time()) if now is None else now
        value, expires = validate_batch(body, now)
        digest = hashlib.sha256(body).hexdigest()
        installation = value['installationId']
        with self.database() as conn:
            conn.execute('BEGIN IMMEDIATE')
            self.prune_conn(conn, now)
            row = conn.execute('SELECT state FROM batches WHERE id=?', (digest,)).fetchone()
            if row:
                return {'id': digest, 'state': row['state'], 'duplicate': True}
            # No raw IPs, credentials or hardware identifiers are persisted.
            for key, limit in [('device:' + installation, 128), ('peer:' + quota, 1024)]:
                row = conn.execute('SELECT count FROM limits WHERE key=? AND hour=?', (key, now // 3600)).fetchone()
                if row and row[0] >= limit:
                    raise StoreLimit('diagnostic_rate_limit')
                conn.execute('INSERT INTO limits VALUES(?,?,1) ON CONFLICT(key,hour) DO UPDATE SET count=count+1', (key, now // 3600))
            used = conn.execute('SELECT coalesce(sum(length(body)),0) FROM batches').fetchone()[0]
            if used + len(body) > self.maximum or conn.execute('SELECT count(*) FROM batches').fetchone()[0] >= 100000:
                raise StoreLimit('diagnostic_storage_full')
            conn.execute('INSERT INTO batches(id,body,installation,received,expires,state) VALUES(?,?,?,?,?,?)',
                         (digest, body, installation, now, expires, self.initial_state))
        return {'id': digest, 'state': self.initial_state, 'duplicate': False}

    def receipt(self, digest, now=None):
        if not ID.fullmatch(digest):
            return None
        now = int(time.time()) if now is None else now
        with self.database() as conn:
            row = conn.execute('SELECT id,state FROM batches WHERE id=? AND expires>?', (digest, now)).fetchone()
        return dict(row) if row else None

    def due(self, limit=5, now=None):
        now = int(time.time()) if now is None else now
        with self.database() as conn:
            self.prune_conn(conn, now)
            return [dict(row) for row in conn.execute("SELECT id,body,attempts FROM batches WHERE state='relay_stored' AND next_retry<=? ORDER BY received,id LIMIT ?", (now, min(limit, 5)))]

    def forwarded(self, digest):
        with self.database() as conn:
            # Keep a small receipt, discard the relay payload only after a
            # hash-verified origin acknowledgment. Origin remains authoritative.
            conn.execute("UPDATE batches SET body=NULL,state='origin_accepted' WHERE id=?", (digest,))

    def retry(self, digest, *, permanent=False, retry_after=0, now=None):
        now = int(time.time()) if now is None else now
        with self.database() as conn:
            row = conn.execute('SELECT attempts FROM batches WHERE id=?', (digest,)).fetchone()
            if not row:
                return
            attempt = row[0] + 1
            delay = max(min(retry_after, RETENTION), min(21600, 30 * 2 ** min(attempt, 10)))
            conn.execute('UPDATE batches SET attempts=?,next_retry=?,state=? WHERE id=?',
                         (attempt, now + delay, 'rejected' if permanent else 'relay_stored', digest))

    def prune(self, now=None):
        with self.database() as conn:
            self.prune_conn(conn, int(time.time()) if now is None else now)

