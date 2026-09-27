"""Curated public streams and short-lived, anonymous playback observations."""

import hashlib
import ipaddress
import json
import os
import re
import sqlite3
import time
from pathlib import Path
from urllib.parse import urlsplit

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse

BASE = Path(__file__).resolve().parent
DATA = Path(os.environ.get("BOBTV_DATA_DIR", BASE / "data"))
CATALOG = BASE / "sources.json"
REPORT_DB = "source_reports.sqlite3"
REPORT_TTL = 30 * 60
BUCKET = 5 * 60
MAX_BODY = 512
MAX_REPORTS = 100_000
SOURCE_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
FINGERPRINT = re.compile(r"^[a-f0-9]{64}$")
router = APIRouter(prefix="/api/v1")


def migrate(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path, timeout=10) as conn:
        version = conn.execute("PRAGMA user_version").fetchone()[0]
        if version > 1:
            raise RuntimeError("Unsupported source report schema")
        if version == 0:
            conn.execute("BEGIN IMMEDIATE")
            conn.execute("CREATE TABLE reports (source_id TEXT NOT NULL, reporter TEXT NOT NULL, bucket INTEGER NOT NULL, playable INTEGER NOT NULL CHECK (playable IN (0, 1)), received INTEGER NOT NULL, PRIMARY KEY (source_id, reporter, bucket))")
            conn.execute("CREATE INDEX reports_fresh ON reports (source_id, received)")
            conn.execute("CREATE TABLE rate_limits (origin TEXT PRIMARY KEY, window INTEGER NOT NULL, count INTEGER NOT NULL)")
            conn.execute("PRAGMA user_version = 1")


def _database():
    path = DATA / REPORT_DB
    if not path.is_file():
        raise RuntimeError("Run source registry migration before starting the site")
    conn = sqlite3.connect(path, timeout=10)
    if conn.execute("PRAGMA user_version").fetchone()[0] != 1:
        conn.close()
        raise RuntimeError("Unsupported source report schema")
    return conn


def _catalog():
    data = json.loads(CATALOG.read_text(encoding="utf-8"))
    if set(data) != {"sources"} or not isinstance(data["sources"], list) or len(data["sources"]) > 100:
        raise ValueError("Invalid source catalog")
    seen = set()
    for item in data["sources"]:
        if not isinstance(item, dict) or set(item) != {"id", "name", "url"}:
            raise ValueError("Invalid source entry")
        source_id, name, url = item["id"], item["name"], item["url"]
        if not isinstance(source_id, str) or not SOURCE_ID.fullmatch(source_id) or source_id in seen:
            raise ValueError("Invalid or duplicate source ID")
        if not isinstance(name, str) or not 1 <= len(name) <= 64:
            raise ValueError("Invalid source metadata")
        validate_public_url(url)
        seen.add(source_id)
    return data["sources"]


def validate_public_url(url):
    if not isinstance(url, str) or len(url) > 2048 or any(ord(char) <= 32 for char in url):
        raise ValueError("Invalid source URL")
    parsed = urlsplit(url)
    host = parsed.hostname
    if parsed.scheme != "https" or not host or parsed.username or parsed.password or parsed.port or parsed.query or parsed.fragment or not parsed.path:
        raise ValueError("Only public HTTPS URLs without credentials or query parameters are allowed")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        if "." not in host or host.endswith((".local", ".internal", ".localhost")):
            raise ValueError("Source hostname must be public") from None
    else:
        raise ValueError("IP-literal source URLs are not allowed")


def _health(conn, source_id, now):
    rows = conn.execute(
        "SELECT playable FROM (SELECT playable, ROW_NUMBER() OVER (PARTITION BY reporter ORDER BY received DESC) AS rank FROM reports WHERE source_id = ? AND received > ?) WHERE rank = 1",
        (source_id, now - REPORT_TTL),
    ).fetchall()
    playable = sum(row[0] for row in rows)
    return {"recentPlayable": playable, "recentFailed": len(rows) - playable, "windowSeconds": REPORT_TTL}


@router.get("/sources")
def sources():
    now = int(time.time())
    with _database() as conn:
        items = [{**item, "feedback": _health(conn, item["id"], now)} for item in _catalog()]
    return JSONResponse({"sources": items}, headers={"Cache-Control": "no-store"})


@router.post("/source-reports")
async def source_report(request: Request):
    if request.headers.get("content-type", "").split(";", 1)[0] != "application/json":
        raise HTTPException(415, "Expected application/json")
    declared = request.headers.get("content-length")
    if declared and declared.isdecimal() and int(declared) > MAX_BODY:
        raise HTTPException(413, "Report exceeds 512 bytes")
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > MAX_BODY:
            raise HTTPException(413, "Report exceeds 512 bytes")
    try:
        data = json.loads(body)
        if not isinstance(data, dict) or set(data) != {"sourceId", "fingerprint", "playable"}:
            raise ValueError("Unexpected report fields")
        if not isinstance(data["sourceId"], str) or not SOURCE_ID.fullmatch(data["sourceId"]):
            raise ValueError("Invalid source ID")
        if not isinstance(data["fingerprint"], str) or not FINGERPRINT.fullmatch(data["fingerprint"]):
            raise ValueError("Invalid fingerprint")
        if type(data["playable"]) is not bool:
            raise ValueError("Invalid playback result")
    except (ValueError, TypeError, UnicodeError) as exc:
        raise HTTPException(422, "Invalid source report") from exc

    if data["sourceId"] not in {item["id"] for item in _catalog()}:
        raise HTTPException(404, "Unknown source")
    now = int(time.time())
    origin = request.client.host if request.client else "unknown"
    origin_hash = hashlib.sha256(f"{now // 86400}:{origin}".encode()).hexdigest()
    reporter_hash = hashlib.sha256(data["fingerprint"].encode()).hexdigest()
    with _database() as conn:
        conn.execute("DELETE FROM reports WHERE received <= ?", (now - REPORT_TTL,))
        conn.execute("DELETE FROM rate_limits WHERE window < ?", (now // 3600 - 1,))
        window = now // 3600
        row = conn.execute("SELECT window, count FROM rate_limits WHERE origin = ?", (origin_hash,)).fetchone()
        count = row[1] + 1 if row and row[0] == window else 1
        conn.execute("INSERT INTO rate_limits VALUES (?, ?, ?) ON CONFLICT(origin) DO UPDATE SET window=excluded.window, count=excluded.count", (origin_hash, window, count))
        if count > 3600:
            raise HTTPException(429, "Hourly report limit reached", headers={"Retry-After": "3600"})
        existing = conn.execute("SELECT 1 FROM reports WHERE source_id = ? AND reporter = ? AND bucket = ?", (data["sourceId"], reporter_hash, now // BUCKET)).fetchone()
        if not existing and conn.execute("SELECT count(*) FROM reports").fetchone()[0] >= MAX_REPORTS:
            raise HTTPException(503, "Report storage is full", headers={"Retry-After": "300"})
        conn.execute(
            "INSERT INTO reports VALUES (?, ?, ?, ?, ?) ON CONFLICT(source_id, reporter, bucket) DO UPDATE SET playable=excluded.playable, received=excluded.received",
            (data["sourceId"], reporter_hash, now // BUCKET, int(data["playable"]), now),
        )
    return JSONResponse({"accepted": True}, status_code=202, headers={"Cache-Control": "no-store"})
