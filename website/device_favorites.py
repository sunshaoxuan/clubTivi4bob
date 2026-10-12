"""Device-private favorite backups, isolated from every public catalog table."""
import hashlib
import hmac
import json
import os
import re
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse, Response

DATA = Path(os.environ.get('BOBTV_DATA_DIR', Path(__file__).parent / 'data'))
router = APIRouter(prefix='/api/v1/device-favorites')
MAX_BODY = 512 * 1024
MAX_DEVICES = 20000
MAX_STORAGE = 256 * 1024 * 1024
PRIVATE_HEADERS = {'Cache-Control': 'private, no-store',
                   'Vary': 'Authorization, X-BobTV-Device-Fingerprint'}


def reject(code, reason):
    raise HTTPException(code, reason, headers=PRIVATE_HEADERS)


def identity(request):
    # A public machine fingerprint is not an authentication credential. A
    # separate 256-bit OS-protected device secret owns this private namespace.
    auth = request.headers.get('authorization', '')
    fingerprint = request.headers.get('x-bobtv-device-fingerprint', '')
    if request.url.query or not re.fullmatch(r'Bearer btvf1_[a-f0-9]{64}', auth):
        reject(401, 'Device credential required')
    if not re.fullmatch(r'[a-f0-9]{64}', fingerprint):
        reject(401, 'Device fingerprint required')
    owner = hashlib.sha256(('BobTV-private-favorites-v1|' + auth[7:]).encode()).hexdigest()
    return owner, hashlib.sha256(fingerprint.encode()).hexdigest()


def text(value, limit, *, pattern=None):
    if (not isinstance(value, str) or not 1 <= len(value) <= limit
            or any(ord(c) < 32 for c in value)
            or pattern and not re.fullmatch(pattern, value)):
        raise ValueError('Invalid favorite metadata')
    return value


def validate_snapshot(value):
    if not isinstance(value, dict) or set(value) != {'lists', 'legacyRoutes'}:
        raise ValueError('Invalid favorite snapshot')
    lists, legacy = value['lists'], value['legacyRoutes']
    if not isinstance(lists, list) or len(lists) > 100 or not isinstance(legacy, list):
        raise ValueError('Invalid favorite lists')
    seen, total = set(), len(legacy)
    for entry in lists:
        if not isinstance(entry, dict) or set(entry) != {'id', 'name', 'icon', 'sortOrder', 'routes'}:
            raise ValueError('Invalid favorite list')
        identifier = text(entry['id'], 80, pattern=r'[a-zA-Z0-9_-]+')
        if identifier in seen:
            raise ValueError('Duplicate favorite list')
        seen.add(identifier)
        text(entry['name'], 128)
        text(entry['icon'], 64)
        if type(entry['sortOrder']) is not int or not 0 <= entry['sortOrder'] <= 100000:
            raise ValueError('Invalid favorite order')
        routes = entry['routes']
        if not isinstance(routes, list) or len(routes) != len(set(routes)):
            raise ValueError('Duplicate favorite route')
        for route in routes:
            text(route, 64, pattern=r'[a-f0-9]{64}')
        total += len(routes)
    if total > 5000 or len(legacy) != len(set(legacy)):
        raise ValueError('Favorite backup exceeds limit')
    for route in legacy:
        text(route, 64, pattern=r'[a-f0-9]{64}')
    return value


@contextmanager
def database():
    DATA.mkdir(parents=True, exist_ok=True)
    path = DATA / 'device_favorites.sqlite3'
    conn = sqlite3.connect(path, timeout=10)
    path.chmod(0o600)
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA journal_mode=WAL')
    conn.execute('CREATE TABLE IF NOT EXISTS favorites(owner TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, revision INTEGER NOT NULL, snapshot TEXT NOT NULL, updated INTEGER NOT NULL)')
    conn.execute('CREATE TABLE IF NOT EXISTS limits(owner TEXT PRIMARY KEY, hour INTEGER NOT NULL, count INTEGER NOT NULL)')
    try:
        with conn:
            conn.execute('BEGIN IMMEDIATE')
            yield conn
    finally:
        conn.close()


def current(conn, owner, fingerprint):
    now = int(time.time())
    old = conn.execute('SELECT hour,count FROM limits WHERE owner=?', (owner,)).fetchone()
    count = old['count'] + 1 if old and old['hour'] == now // 3600 else 1
    if count > 500:
        reject(429, 'Private backup rate limit')
    conn.execute('DELETE FROM limits WHERE hour<?', (now // 3600 - 1,))
    conn.execute('INSERT INTO limits VALUES(?,?,?) ON CONFLICT(owner) DO UPDATE SET hour=excluded.hour,count=excluded.count', (owner, now // 3600, count))
    # Preserve rate accounting even for missing backups or rejected revisions.
    conn.commit()
    conn.execute('BEGIN IMMEDIATE')
    row = conn.execute('SELECT * FROM favorites WHERE owner=?', (owner,)).fetchone()
    if row and not hmac.compare_digest(row['fingerprint'], fingerprint):
        reject(403, 'Backup belongs to a different device')
    return row


@router.get('')
def fetch(request: Request):
    owner, fingerprint = identity(request)
    with database() as conn:
        row = current(conn, owner, fingerprint)
        if not row:
            reject(404, 'No backup for this device')
        etag = f'"favorites-v1-{row["revision"]}"'
        headers = {**PRIVATE_HEADERS, 'ETag': etag}
        if request.headers.get('if-none-match') == etag:
            return Response(status_code=304, headers=headers)
        return JSONResponse({'schemaVersion': 1, 'revision': row['revision'],
                             'updatedAt': row['updated'], 'snapshot': json.loads(row['snapshot'])},
                            headers=headers)


@router.put('')
async def save(request: Request):
    owner, fingerprint = identity(request)
    if request.headers.get('content-type', '').split(';')[0] != 'application/json':
        reject(415, 'JSON required')
    body = bytearray()
    async for part in request.stream():
        body.extend(part)
        if len(body) > MAX_BODY:
            reject(413, 'Favorite backup exceeds limit')
    try:
        value = json.loads(body)
        if (not isinstance(value, dict) or set(value) != {'schemaVersion', 'baseRevision', 'snapshot'}
                or type(value['schemaVersion']) is not int or value['schemaVersion'] != 1 or type(value['baseRevision']) is not int
                or not 0 <= value['baseRevision'] <= 2**53-1):
            raise ValueError('Invalid backup request')
        snapshot = validate_snapshot(value['snapshot'])
        encoded = json.dumps(snapshot, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
    except (ValueError, TypeError):
        reject(422, 'Invalid favorite backup')
    with database() as conn:
        row = current(conn, owner, fingerprint)
        revision = row['revision'] if row else 0
        if row and row['snapshot'] == encoded:
            return JSONResponse({'revision': revision, 'duplicate': True}, headers=PRIVATE_HEADERS)
        if value['baseRevision'] != revision:
            reject(409, 'Favorite backup revision changed')
        count, size = conn.execute('SELECT count(*),COALESCE(sum(length(CAST(snapshot AS BLOB))),0) FROM favorites').fetchone()
        if (not row and count >= MAX_DEVICES) or size - (len(row['snapshot'].encode()) if row else 0) + len(encoded.encode()) > MAX_STORAGE:
            reject(503, 'Private backup capacity reached')
        revision += 1
        conn.execute('INSERT INTO favorites VALUES(?,?,?,?,?) ON CONFLICT(owner) DO UPDATE SET revision=excluded.revision,snapshot=excluded.snapshot,updated=excluded.updated',
                     (owner, fingerprint, revision, encoded, int(time.time())))
    return JSONResponse({'revision': revision, 'duplicate': False}, headers=PRIVATE_HEADERS)
