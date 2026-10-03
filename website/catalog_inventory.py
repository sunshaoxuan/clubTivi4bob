"""Persistent public channel inventory contributed by BobTV installations."""
import hashlib
import ipaddress
import json
import os
import re
import sqlite3
import time
from pathlib import Path
from contextlib import contextmanager
from urllib.parse import urlsplit, parse_qsl

from fastapi import APIRouter, HTTPException, Request, BackgroundTasks
from fastapi.responses import JSONResponse
from route_identity import canonical_route_url

DATA = Path(os.environ.get("BOBTV_DATA_DIR", Path(__file__).parent / "data"))
router = APIRouter(prefix="/api/v1/channel-catalog")
MAX_BODY = 512 * 1024


def validate_media_url(url):
    if not isinstance(url, str) or not 1 <= len(url) <= 2048 or any(ord(c) <= 32 for c in url):
        raise ValueError("Invalid media URL")
    parsed = urlsplit(url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme not in ("https", "http") or not host or parsed.username or parsed.password or parsed.fragment:
        raise ValueError("Invalid public media URL")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        if "." not in host or host.endswith((".local", ".internal", ".localhost")):
            raise ValueError("Private hostname") from None
    else:
        if not address.is_global:
            raise ValueError("Private address")
    if any(re.search(r"token|password|secret|auth|api.?key", key, re.I) for key, _ in parse_qsl(parsed.query)):
        raise ValueError("Credential-bearing media URL")
    segments = [part for part in parsed.path.split('/') if part]
    if len(segments) >= 4 and segments[0].lower() in ('live', 'movie', 'series'):
        raise ValueError("Account-bearing media URL")
    if parsed.port is not None and not 1 <= parsed.port <= 65535:
        raise ValueError("Invalid port")
    return canonical_route_url(url)


def _migrate_route_identity(conn):
    conn.execute('CREATE TABLE IF NOT EXISTS catalog_migrations (name TEXT PRIMARY KEY)')
    if conn.execute("SELECT 1 FROM catalog_migrations WHERE name='route_identity_v1'").fetchone():
        return
    groups = {}
    for row in conn.execute('SELECT * FROM routes').fetchall():
        url = canonical_route_url(row['url'])
        groups.setdefault(url, []).append(dict(row))
    for url, rows in groups.items():
        digest = hashlib.sha256(url.encode()).hexdigest()
        if len(rows) == 1 and rows[0]['digest'] == digest and rows[0]['url'] == url:
            conn.execute('INSERT OR IGNORE INTO route_origins VALUES (?,?)', (digest, rows[0]['source']))
            continue
        winner = max(rows, key=lambda r: (r['manual_category'], r['revision'], r['received'], r['digest']))
        merged = {**winner, 'url': url, 'digest': digest}
        for field in ('blocked', 'deleted', 'manual_category', 'received', 'failures'):
            merged[field] = max(r[field] for r in rows)
        for field in ('playable_at', 'checked_at', 'success_at'):
            merged[field] = max((r[field] for r in rows if r[field] is not None), default=None)
        for field in ('success_votes', 'failure_votes'):
            merged[field] = sum(r[field] for r in rows)
        merged['revision'] = max(r['revision'] for r in rows) + (len(rows) > 1)
        for row in rows:
            origins = conn.execute('SELECT source FROM route_origins WHERE digest=?', (row['digest'],)).fetchall()
            conn.execute('DELETE FROM route_origins WHERE digest=?', (row['digest'],))
            for source in {row['source'], *(r[0] for r in origins)}:
                conn.execute('INSERT OR IGNORE INTO route_origins VALUES (?,?)', (digest, source))
            conn.execute('DELETE FROM routes WHERE digest=?', (row['digest'],))
        columns = list(merged)
        conn.execute(f"INSERT INTO routes ({','.join(columns)}) VALUES ({','.join('?' for _ in columns)})", list(merged.values()))
    conn.execute("INSERT INTO catalog_migrations VALUES ('route_identity_v1')")


@contextmanager
def database(data_dir=None):
    directory = Path(data_dir or DATA)
    directory.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(directory / "channel_inventory.sqlite3", timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("CREATE TABLE IF NOT EXISTS routes (digest TEXT PRIMARY KEY, name TEXT NOT NULL, url TEXT NOT NULL, group_name TEXT NOT NULL, source TEXT NOT NULL, epg_id TEXT, logo_url TEXT, playable_at INTEGER, blocked INTEGER NOT NULL DEFAULT 0, received INTEGER NOT NULL, checked_at INTEGER, success_at INTEGER, failures INTEGER NOT NULL DEFAULT 0)")
    conn.execute("CREATE TABLE IF NOT EXISTS batches (reporter TEXT NOT NULL, digest TEXT NOT NULL, received INTEGER NOT NULL, PRIMARY KEY(reporter,digest))")
    conn.execute("CREATE TABLE IF NOT EXISTS limits (reporter TEXT PRIMARY KEY, hour INTEGER NOT NULL, count INTEGER NOT NULL)")
    columns = {row[1] for row in conn.execute('PRAGMA table_info(routes)')}
    for name, definition in {'revision': 'INTEGER NOT NULL DEFAULT 0',
            'deleted': 'INTEGER NOT NULL DEFAULT 0',
            'success_votes': 'INTEGER NOT NULL DEFAULT 0',
            'failure_votes': 'INTEGER NOT NULL DEFAULT 0',
            'manual_category': 'INTEGER NOT NULL DEFAULT 0'}.items():
        if name not in columns:
            conn.execute(f'ALTER TABLE routes ADD COLUMN {name} {definition}')
    conn.execute('CREATE TABLE IF NOT EXISTS sync_receipts (reporter TEXT NOT NULL, event_id TEXT NOT NULL, receipt TEXT NOT NULL, PRIMARY KEY(reporter,event_id))')
    conn.execute('CREATE TABLE IF NOT EXISTS route_origins (digest TEXT NOT NULL, source TEXT NOT NULL, PRIMARY KEY(digest,source))')
    try:
        with conn:
            _migrate_route_identity(conn)
            conn.execute('CREATE UNIQUE INDEX IF NOT EXISTS routes_url_unique ON routes(url)')
            yield conn
    finally:
        conn.close()


def ingest(rows, fingerprint, data_dir=None):
    now = int(time.time())
    accepted = 0
    skipped = 0
    normalized = []
    for row in rows:
        try:
            if not isinstance(row, dict): raise ValueError()
            url = validate_media_url(row.get("url"))
            name, group, source = row.get("name"), row.get("group"), row.get("source")
            if not all(isinstance(value, str) and 1 <= len(value) <= limit
                       and not any(ord(c) < 32 for c in value)
                       for value, limit in ((name, 128), (group, 192), (source, 128))):
                raise ValueError()
            if type(row.get("blocked")) is not bool: raise ValueError()
            playable = row.get("playableAt")
            if playable is not None and (type(playable) is not int or playable > now + 300 or playable < 0): raise ValueError()
            epg = row.get("epgId")
            if epg is not None and (not isinstance(epg, str) or len(epg) > 128): raise ValueError()
            logo = row.get("logoUrl")
            if logo is not None:
                try: validate_media_url(logo)
                except ValueError: logo = None
            normalized.append((hashlib.sha256(url.encode()).hexdigest(), name, url, group, source, epg, logo, playable, int(row["blocked"]), now))
        except (ValueError, TypeError):
            skipped += 1
    reporter = hashlib.sha256(fingerprint.encode()).hexdigest()
    batch_digest = hashlib.sha256(json.dumps(normalized, ensure_ascii=False).encode()).hexdigest()
    with database(data_dir) as conn:
        limit = conn.execute("SELECT hour,count FROM limits WHERE reporter=?", (reporter,)).fetchone()
        count = limit["count"] + 1 if limit and limit["hour"] == now // 3600 else 1
        if count > 2000: raise HTTPException(429, "Inventory rate limit", headers={"Retry-After": "3600"})
        conn.execute("INSERT INTO limits VALUES (?,?,?) ON CONFLICT(reporter) DO UPDATE SET hour=excluded.hour,count=excluded.count", (reporter, now // 3600, count))
        total = conn.execute("SELECT count(*) FROM routes").fetchone()[0]
        for item in normalized:
            if not conn.execute('SELECT 1 FROM routes WHERE digest=?', (item[0],)).fetchone():
                if total >= 250000: raise HTTPException(503, "Inventory capacity reached")
                total += 1
            # Repeated discovery must not overwrite reviewed/manual metadata.
            conn.execute("INSERT INTO routes (digest,name,url,group_name,source,epg_id,logo_url,playable_at,blocked,received) VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(digest) DO UPDATE SET playable_at=MAX(COALESCE(routes.playable_at,0),COALESCE(excluded.playable_at,0)),blocked=MAX(routes.blocked,excluded.blocked),received=excluded.received", item)
            conn.execute('INSERT OR IGNORE INTO route_origins VALUES (?,?)', (item[0], item[4]))
            accepted += 1
        conn.execute("DELETE FROM batches WHERE received<?", (now - 7 * 86400,))
        conn.execute("INSERT OR REPLACE INTO batches VALUES (?,?,?)", (reporter, batch_digest, now))
        counts = conn.execute("SELECT count(*),sum(blocked),sum(success_at IS NOT NULL AND blocked=0) FROM routes").fetchone()
    return {"accepted": accepted, "skipped": skipped, "storedRoutes": counts[0], "blockedRoutes": counts[1] or 0, "verifiedRoutes": counts[2] or 0}


@router.post("/inventory")
async def inventory(request: Request):
    if request.headers.get("content-type", "").split(";", 1)[0] != "application/json":
        raise HTTPException(415)
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > MAX_BODY: raise HTTPException(413)
    try:
        payload = json.loads(body)
        if not isinstance(payload, dict) or payload.get("schemaVersion") != 1 or not re.fullmatch(r"[a-f0-9]{64}", payload.get("fingerprint", "")):
            raise ValueError()
        rows = payload.get("routes")
        if not isinstance(rows, list) or not 1 <= len(rows) <= 200: raise ValueError()
    except (ValueError, TypeError):
        raise HTTPException(422, "Invalid inventory batch") from None
    return JSONResponse(ingest(rows, payload["fingerprint"]), status_code=202)


@router.get("/blocked")
def blocked_routes():
    with database() as conn:
        urls = [row[0] for row in conn.execute("SELECT url FROM routes WHERE blocked=1 OR deleted=1 ORDER BY digest")]
    return {"schemaVersion": 1, "urls": urls}


def ingest_events(events, fingerprint, data_dir=None):
    reporter = hashlib.sha256(fingerprint.encode()).hexdigest()
    receipts = []
    with database(data_dir) as conn:
        now=int(time.time())
        limit=conn.execute('SELECT hour,count FROM limits WHERE reporter=?',(reporter,)).fetchone()
        count=limit['count']+1 if limit and limit['hour']==now//3600 else 1
        if count>2000: raise HTTPException(429,'Sync rate limit',headers={'Retry-After':'3600'})
        conn.execute('INSERT INTO limits VALUES(?,?,?) ON CONFLICT(reporter) DO UPDATE SET hour=excluded.hour,count=excluded.count',(reporter,now//3600,count))
        total=conn.execute('SELECT count(*) FROM routes').fetchone()[0]
        for event in events:
            if not isinstance(event, dict) or not isinstance(event.get('id'),str) or not re.fullmatch(r'[a-f0-9-]{16,80}', event['id']):
                raise HTTPException(422, 'Invalid event ID')
            event_id = event['id']
            saved = conn.execute('SELECT receipt FROM sync_receipts WHERE reporter=? AND event_id=?', (reporter, event_id)).fetchone()
            if saved:
                receipts.append(json.loads(saved[0]))
                continue
            receipt = {'id': event_id, 'status': 'rejected', 'revision': 0}
            try:
                url = validate_media_url(event.get('url'))
                kind = event.get('kind')
                digest = hashlib.sha256(url.encode()).hexdigest()
                row = conn.execute('SELECT * FROM routes WHERE digest=?', (digest,)).fetchone()
                if kind == 'upsert':
                    metadata = event.get('metadata')
                    if not isinstance(metadata, dict): raise ValueError('Missing metadata')
                    # Insert through the same privacy and validation policy.
                    normalized = {**metadata, 'url': url, 'blocked': False}
                    name, group, source = normalized.get('name'), normalized.get('group'), normalized.get('source')
                    if not all(isinstance(v, str) and 1 <= len(v) <= limit and not any(ord(c) < 32 for c in v)
                               for v, limit in ((name,128),(group,192),(source,128))): raise ValueError('Invalid metadata')
                    epg,logo=normalized.get('epgId'),normalized.get('logoUrl')
                    if epg is not None and (not isinstance(epg,str) or len(epg)>128): raise ValueError('Invalid EPG')
                    if logo is not None: validate_media_url(logo)
                    if row is None:
                        if total>=250000: raise HTTPException(503,'Inventory capacity reached')
                        total+=1
                        conn.execute('INSERT INTO routes(digest,name,url,group_name,source,received) VALUES(?,?,?,?,?,?)', (digest,name,url,group,source,int(time.time())))
                        row = conn.execute('SELECT * FROM routes WHERE digest=?', (digest,)).fetchone()
                        conn.execute('UPDATE routes SET epg_id=?,logo_url=? WHERE digest=?',(epg,logo,digest))
                    conn.execute('INSERT OR IGNORE INTO route_origins VALUES (?,?)', (digest, source))
                elif kind not in ('classify', 'health', 'delete', 'retire'):
                    raise ValueError('Unknown event')
                if row is None:
                    if kind in ('delete', 'retire'):
                        conn.execute('INSERT INTO routes(digest,name,url,group_name,source,received) VALUES(?,?,?,?,?,?)', (digest,'已删除线路',url,'其他','BobTV',int(time.time())))
                        row = conn.execute('SELECT * FROM routes WHERE digest=?', (digest,)).fetchone()
                    else:
                        receipt['status'] = 'retry'
                        receipts.append(receipt)
                        continue
                revision = row['revision']
                if kind == 'classify':
                    group = event.get('group')
                    if not isinstance(group,str) or not 1 <= len(group) <= 192 or any(ord(c)<32 for c in group): raise ValueError('Invalid group')
                    base = event.get('baseRevision')
                    if type(base) is not int or base != revision:
                        receipt.update(status='conflict', revision=revision)
                    else:
                        conn.execute('UPDATE routes SET group_name=?,manual_category=1,revision=revision+1 WHERE digest=?', (group,digest))
                        receipt.update(status='applied', revision=revision+1)
                elif kind == 'health':
                    success, failure = event.get('success',0), event.get('failure',0)
                    if not all(type(v) is int and 0 <= v <= 10 for v in (success,failure)) or not success+failure: raise ValueError('Invalid health observation')
                    conn.execute('UPDATE routes SET success_votes=success_votes+?,failure_votes=failure_votes+? WHERE digest=?', (success,failure,digest))
                    receipt.update(status='applied', revision=revision)
                elif kind in ('delete','retire'):
                    column = 'blocked' if kind == 'retire' else 'deleted'
                    changed = not row[column]
                    conn.execute(f'UPDATE routes SET {column}=1,revision=revision+? WHERE digest=?', (int(changed),digest))
                    receipt.update(status='applied',revision=revision+int(changed))
                else:
                    group = row['group_name'] if row['manual_category'] else metadata['group']
                    changed=(name,group,epg,logo)!=(row['name'],row['group_name'],row['epg_id'],row['logo_url'])
                    if changed and not row['blocked'] and not row['deleted']:
                        if event.get('baseRevision',0)!=revision:
                            receipt.update(status='conflict',revision=revision)
                        else:
                            conn.execute('UPDATE routes SET name=?,group_name=?,epg_id=?,logo_url=?,revision=revision+1 WHERE digest=?',(name,group,epg,logo,digest))
                            receipt.update(status='applied',revision=revision+1)
                    else:
                        receipt.update(status='applied',revision=revision)
            except (ValueError,TypeError):
                pass
            conn.execute('INSERT INTO sync_receipts VALUES(?,?,?)',(reporter,event_id,json.dumps(receipt)))
            receipts.append(receipt)
    return {'schemaVersion':1, 'receipts':receipts}


@router.post('/events')
async def sync_events(request: Request, background_tasks: BackgroundTasks):
    if request.headers.get('content-type','').split(';',1)[0] != 'application/json': raise HTTPException(415)
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body)>MAX_BODY: raise HTTPException(413)
    try:
        payload = json.loads(body)
        if payload.get('schemaVersion') != 1 or not re.fullmatch(r'[a-f0-9]{64}',payload.get('fingerprint','')): raise ValueError()
        events = payload.get('events')
        if not isinstance(events,list) or not 1 <= len(events) <= 200: raise ValueError()
    except (ValueError,TypeError,AttributeError):
        raise HTTPException(422,'Invalid sync events') from None
    receipt=ingest_events(events,payload['fingerprint'])
    background_tasks.add_task(_publish_changes)
    return JSONResponse(receipt,status_code=202)


def _publish_changes():
    from process_channel_inventory import process
    process(DATA,limit=0)
