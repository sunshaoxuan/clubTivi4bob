"""Bounded, idempotent public requests. External execution belongs to a worker."""
import hashlib
import json
import os
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse

DATA = Path(os.environ.get('BOBTV_DATA_DIR', Path(__file__).parent / 'data'))
router = APIRouter(prefix='/api/v1/server-tasks')


@contextmanager
def database():
    DATA.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DATA / 'server_tasks.sqlite3', timeout=5)
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA journal_mode=WAL')
    conn.execute('BEGIN IMMEDIATE')
    conn.execute('CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload TEXT NOT NULL, state TEXT NOT NULL, result TEXT, created INTEGER NOT NULL, updated INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0)')
    conn.execute('CREATE TABLE IF NOT EXISTS limits (origin TEXT PRIMARY KEY, window INTEGER NOT NULL, count INTEGER NOT NULL)')
    columns = {r[1] for r in conn.execute('PRAGMA table_info(jobs)')}
    for name, definition in {'next_attempt': 'INTEGER NOT NULL DEFAULT 0', 'error_code': 'TEXT'}.items():
        if name not in columns:
            conn.execute(f'ALTER TABLE jobs ADD COLUMN {name} {definition}')
    conn.execute('CREATE INDEX IF NOT EXISTS jobs_queue ON jobs(state,next_attempt,created)')
    conn.execute('CREATE TABLE IF NOT EXISTS starts (job_id TEXT,kind TEXT,started INTEGER)')
    conn.execute('CREATE INDEX IF NOT EXISTS starts_budget ON starts(kind,started)')
    conn.execute('CREATE TABLE IF NOT EXISTS classification_cache (id TEXT PRIMARY KEY,result TEXT NOT NULL,expires INTEGER NOT NULL)')
    conn.execute('CREATE INDEX IF NOT EXISTS classification_expiry ON classification_cache(expires)')
    conn.execute('CREATE TABLE IF NOT EXISTS ai_requests (started INTEGER NOT NULL)')
    conn.execute('CREATE INDEX IF NOT EXISTS ai_request_budget ON ai_requests(started)')
    try:
        conn.commit()
        yield conn
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()


def enqueue(kind, payload):
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
    identity = hashlib.sha256((kind + '\0' + encoded).encode()).hexdigest()
    now = int(time.time())
    with database() as conn:
        conn.execute('BEGIN IMMEDIATE')
        row = conn.execute('SELECT * FROM jobs WHERE id=?', (identity,)).fetchone()
        ttl = 300 if row and row['state'] == 'failed' else (3600 if kind == 'discover' else 7 * 86400)
        if row and (row['state'] in ('queued', 'running') or now - row['updated'] < ttl):
            return dict(row)
        if conn.execute("SELECT count(*) FROM jobs WHERE state IN ('queued','running')").fetchone()[0] >= 500:
            raise HTTPException(503, 'Task queue is full', headers={'Retry-After': '60'})
        conn.execute("INSERT INTO jobs (id,kind,payload,state,created,updated) VALUES (?,?,?,'queued',?,?) ON CONFLICT(id) DO UPDATE SET state='queued',result=NULL,created=excluded.created,updated=excluded.updated,attempts=0,next_attempt=0,error_code=NULL", (identity, kind, encoded, now, now))
        conn.execute("DELETE FROM jobs WHERE updated<? AND state IN ('done','failed')", (now - 30 * 86400,))
        return dict(conn.execute('SELECT * FROM jobs WHERE id=?', (identity,)).fetchone())


def public_result(row):
    items = json.loads(row['result'] or '[]') if row['state'] == 'done' else []
    if row['kind'] in ('category','country'):
        threshold = .95 if row['kind'] == 'country' else .9
        items = [item for item in items if isinstance(item,dict) and type(item.get('confidence')) in (int,float) and threshold <= item['confidence'] <= 1]
    return {'id': row['id'], 'state': row['state'], 'items': items,
            'attempts': row['attempts'], 'updatedAt': row['updated'],
            'nextRetryAt': row['next_attempt'] or None, 'errorCode': row['error_code']}


def read_state(path):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


@router.get('/status')
def status():
    now = int(time.time())
    lanes = {}
    for lane in ('classification', 'discovery'):
        value = read_state(DATA / f'server-worker-{lane}.json')
        lanes[lane] = type(value.get('time')) is int and 0 <= now - value['time'] < 300
    legacy = read_state(DATA / 'server-worker-status.json')
    fresh = any(lanes.values()) or (type(legacy.get('time')) is int and 0 <= now - legacy['time'] < 300)
    health = read_state(DATA / 'server-ai-health.json')
    last_failure = health.get('lastFailure', 0)
    ai_available = fresh and type(health.get('lastSuccess')) is int and type(last_failure) is int and 0 <= now - health['lastSuccess'] < 6 * 3600 and last_failure < health['lastSuccess']
    with database() as conn:
        counts = {r['state']: r['total'] for r in conn.execute('SELECT state,count(*) AS total FROM jobs GROUP BY state')}
        oldest = conn.execute("SELECT min(created) FROM jobs WHERE state='queued'").fetchone()[0]
    return {'execution': 'server', 'workerAvailable': fresh, 'aiAvailable': ai_available,
            'classificationAvailable': ai_available and (lanes['classification'] or not any(lanes.values())),
            'discoveryAvailable': ai_available and (lanes['discovery'] or not any(lanes.values())),
            'queue': {state: counts.get(state, 0) for state in ('queued','running','done','failed')},
            'oldestQueuedSeconds': max(0, now - oldest) if oldest else 0,
            'catalogPath': '/api/v1/channel-catalog/manifest'}


@router.get('/{identity}')
def result(identity: str):
    if len(identity) != 64 or any(c not in '0123456789abcdef' for c in identity): raise HTTPException(404)
    with database() as conn:
        row = conn.execute('SELECT * FROM jobs WHERE id=?', (identity,)).fetchone()
    if row is None: raise HTTPException(404)
    return JSONResponse(public_result(row), headers={'Cache-Control': 'no-store'})


@router.post('')
async def submit(request: Request):
    if request.headers.get('content-type', '').split(';')[0] != 'application/json':
        raise HTTPException(415)
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > 16384: raise HTTPException(413)
    try:
        value = json.loads(body)
        if not isinstance(value, dict) or set(value) != {'kind', 'inputs'}: raise ValueError()
        kind, inputs = value['kind'], value['inputs']
        if kind not in ('category', 'country', 'discover') or not isinstance(inputs, list) or not 1 <= len(inputs) <= 20: raise ValueError()
        cleaned = []
        for item in inputs:
            if not isinstance(item, dict) or set(item) - {'name', 'group', 'tvgId'} or 'name' not in item: raise ValueError()
            if any(not isinstance(v, str) or len(v) > 192 or any(ord(c) < 32 for c in v) for v in item.values()): raise ValueError()
            if not item['name'].strip(): raise ValueError()
            cleaned.append({key: item.get(key, '').strip() for key in ('name', 'group', 'tvgId')})
        if kind == 'discover' and len(cleaned) != 1: raise ValueError()
    except (ValueError, TypeError, UnicodeError):
        raise HTTPException(422, 'Invalid task') from None
    from source_candidates import _attribution
    origin = hashlib.sha256(_attribution(request)[0].encode()).hexdigest()
    window = int(time.time()) // 3600
    with database() as conn:
        conn.execute('DELETE FROM limits WHERE window<?', (window - 1,))
        conn.execute('INSERT INTO limits VALUES (?,?,1) ON CONFLICT(origin) DO UPDATE SET count=CASE WHEN window=excluded.window THEN count+1 ELSE 1 END,window=excluded.window', (origin, window))
        if conn.execute('SELECT count FROM limits WHERE origin=?', (origin,)).fetchone()[0] > 180:
            raise HTTPException(429, headers={'Retry-After': '3600'})
    row = enqueue(kind, cleaned)
    return JSONResponse(public_result(row), status_code=200 if row['state'] == 'done' else 202, headers={'Cache-Control': 'no-store'})
