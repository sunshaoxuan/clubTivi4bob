"""Private, consent-based intake of candidate public playback sources."""

import hashlib
import ipaddress
import json
import os
import re
import sqlite3
import time
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse

from source_registry import FINGERPRINT, validate_public_url

BASE = Path(__file__).resolve().parent
DATA = Path(os.environ.get("BOBTV_DATA_DIR", BASE / "data"))
DATABASE = "source_candidates.sqlite3"
RETENTION = 14 * 86400
MAX_BODY = 4096
MAX_CANDIDATES = 10_000
DEVICES = {"Windows", "Android", "iOS", "macOS", "Linux", "Other"}
COUNTRY = re.compile(r"^[A-Z]{2}$")
CF_RANGES = tuple(ipaddress.ip_network(value) for value in json.loads((BASE / "cloudflare_ranges.json").read_text(encoding="utf-8"))["ranges"])
router = APIRouter(prefix="/api/v1")


def migrate(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path, timeout=10) as conn:
        version = conn.execute("PRAGMA user_version").fetchone()[0]
        if version > 1:
            raise RuntimeError("Unsupported candidate schema")
        if version == 0:
            conn.execute("BEGIN IMMEDIATE")
            conn.execute("CREATE TABLE candidates (digest TEXT NOT NULL, client_hash TEXT NOT NULL, day INTEGER NOT NULL, name TEXT NOT NULL, url TEXT NOT NULL, ip TEXT NOT NULL, device TEXT NOT NULL, country TEXT, received INTEGER NOT NULL, PRIMARY KEY (digest, client_hash, day))")
            conn.execute("CREATE INDEX candidates_recent ON candidates (received)")
            conn.execute("CREATE TABLE rate_limits (origin TEXT PRIMARY KEY, window INTEGER NOT NULL, count INTEGER NOT NULL)")
            conn.execute("PRAGMA user_version = 1")
    os.chmod(path, 0o600)


def _database():
    path = DATA / DATABASE
    if not path.is_file():
        raise RuntimeError("Run candidate migration before starting the site")
    conn = sqlite3.connect(path, timeout=10)
    if conn.execute("PRAGMA user_version").fetchone()[0] != 1:
        conn.close()
        raise RuntimeError("Unsupported candidate schema")
    return conn


def _attribution(request: Request):
    peer = request.client.host if request.client else ""
    try:
        edge = ipaddress.ip_address(peer)
    except ValueError:
        return "unknown", None
    if not any(edge in network for network in CF_RANGES):
        return str(edge), None
    try:
        client = ipaddress.ip_address(request.headers.get("cf-connecting-ip", ""))
    except ValueError:
        return "unknown", None
    country = request.headers.get("cf-ipcountry", "")
    return str(client), country if COUNTRY.fullmatch(country) and country != "XX" else None


def prune(conn, now):
    conn.execute("DELETE FROM candidates WHERE received <= ?", (now - RETENTION,))
    conn.execute("DELETE FROM rate_limits WHERE window < ?", (now // 3600 - 1,))


@router.post("/source-candidates")
async def candidate(request: Request):
    if request.headers.get("content-type", "").split(";", 1)[0] != "application/json":
        raise HTTPException(415, "Expected application/json")
    declared = request.headers.get("content-length")
    if declared and declared.isdecimal() and int(declared) > MAX_BODY:
        raise HTTPException(413, "Candidate exceeds 4 KiB")
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > MAX_BODY:
            raise HTTPException(413, "Candidate exceeds 4 KiB")
    try:
        data = json.loads(body)
        if not isinstance(data, dict) or set(data) != {"name", "url", "device", "fingerprint", "consent"} or data["consent"] is not True:
            raise ValueError("Consent and exact fields are required")
        if not isinstance(data["name"], str) or not 1 <= len(data["name"]) <= 64 or any(ord(char) < 32 for char in data["name"]):
            raise ValueError("Invalid source name")
        validate_public_url(data["url"])
        if data["device"] not in DEVICES:
            raise ValueError("Invalid device category")
        if not isinstance(data["fingerprint"], str) or not FINGERPRINT.fullmatch(data["fingerprint"]):
            raise ValueError("Invalid fingerprint")
    except (ValueError, TypeError, UnicodeError) as exc:
        raise HTTPException(422, "Invalid public source candidate") from exc

    now = int(time.time())
    ip, country = _attribution(request)
    origin = hashlib.sha256(f"{now // 86400}:{ip}".encode()).hexdigest()
    client_hash = hashlib.sha256(data["fingerprint"].encode()).hexdigest()
    digest = hashlib.sha256(data["url"].encode()).hexdigest()
    with _database() as conn:
        prune(conn, now)
        window = now // 3600
        row = conn.execute("SELECT window, count FROM rate_limits WHERE origin = ?", (origin,)).fetchone()
        count = row[1] + 1 if row and row[0] == window else 1
        conn.execute("INSERT INTO rate_limits VALUES (?, ?, ?) ON CONFLICT(origin) DO UPDATE SET window=excluded.window, count=excluded.count", (origin, window, count))
        if count > 30:
            raise HTTPException(429, "Hourly candidate limit reached", headers={"Retry-After": "3600"})
        existing = conn.execute("SELECT 1 FROM candidates WHERE digest = ? AND client_hash = ? AND day = ?", (digest, client_hash, now // 86400)).fetchone()
        if not existing and conn.execute("SELECT count(*) FROM candidates").fetchone()[0] >= MAX_CANDIDATES:
            raise HTTPException(503, "Candidate storage is full", headers={"Retry-After": "3600"})
        conn.execute(
            "INSERT INTO candidates VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(digest, client_hash, day) DO UPDATE SET name=excluded.name, ip=excluded.ip, device=excluded.device, country=excluded.country, received=excluded.received",
            (digest, client_hash, now // 86400, data["name"], data["url"], ip, data["device"], country, now),
        )
    return JSONResponse({"id": digest[:12], "pendingReview": True}, status_code=202, headers={"Cache-Control": "no-store"})
