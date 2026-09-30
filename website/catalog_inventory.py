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

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse

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
    return url


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
    try:
        with conn:
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
        if total + len(normalized) > 250000: raise HTTPException(503, "Inventory capacity reached")
        for item in normalized:
            conn.execute("INSERT INTO routes (digest,name,url,group_name,source,epg_id,logo_url,playable_at,blocked,received) VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(digest) DO UPDATE SET name=excluded.name,group_name=excluded.group_name,source=excluded.source,epg_id=excluded.epg_id,logo_url=excluded.logo_url,playable_at=MAX(COALESCE(routes.playable_at,0),COALESCE(excluded.playable_at,0)),blocked=MAX(routes.blocked,excluded.blocked),received=excluded.received", item)
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
        urls = [row[0] for row in conn.execute("SELECT url FROM routes WHERE blocked=1 ORDER BY digest")]
    return {"schemaVersion": 1, "urls": urls}
