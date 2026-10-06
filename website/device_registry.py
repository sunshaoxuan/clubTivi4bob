"""Hardware-host registry. Schema creation is an explicit deployment step."""
import hashlib
import json
import os
import re
import sqlite3
import time
from contextlib import closing
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse

DATA = Path(os.environ.get("BOBTV_DATA_DIR", Path(__file__).resolve().parent / "data"))
router = APIRouter()
PATTERN = re.compile(r"^bth1_[a-f0-9]{64}$")
MAX_HOSTS = 100000

def migrate(data):
    """Version 1; never backfill salted installation identities."""
    data.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(data / "device_registry.sqlite3")) as conn, conn:
        conn.execute("BEGIN IMMEDIATE")
        version = conn.execute("PRAGMA user_version").fetchone()[0]
        if version not in (0, 1):
            raise ValueError("Unsupported host registry schema")
        if version == 0:
            conn.execute("CREATE TABLE hosts (identity TEXT PRIMARY KEY, first_seen INTEGER NOT NULL)")
            conn.execute("CREATE TABLE attempts (peer TEXT PRIMARY KEY, hour INTEGER NOT NULL, count INTEGER NOT NULL)")
            conn.execute("PRAGMA user_version=1")

def database(data=None, write=False):
    path = (data if data is not None else DATA) / "device_registry.sqlite3"
    conn = sqlite3.connect(path.resolve().as_uri() + ("?mode=rw" if write else "?mode=ro"), uri=True, timeout=2)
    try:
        if conn.execute("PRAGMA user_version").fetchone()[0] != 1:
            raise sqlite3.DatabaseError("Host registry migration required")
    except sqlite3.Error:
        conn.close()
        raise
    return conn

def installed_device_count(data=None):
    try:
        with closing(database(data)) as conn:
            return conn.execute("SELECT COUNT(*) FROM hosts").fetchone()[0]
    except sqlite3.Error:
        return None

@router.get("/api/v1/devices/count")
def count():
    value = installed_device_count()
    return JSONResponse({"count": value}, status_code=200 if value is not None else 503,
                        headers={"Cache-Control": "no-store"})

@router.post("/api/v1/devices/register")
async def register(request: Request):
    if request.headers.get("content-type", "").split(";", 1)[0] != "application/json":
        raise HTTPException(415)
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > 256:
            raise HTTPException(413)
    try:
        payload = json.loads(body)
        if not isinstance(payload, dict) or set(payload) != {"hostFingerprint"}:
            raise ValueError()
        identity = payload["hostFingerprint"]
        if not isinstance(identity, str) or not PATTERN.fullmatch(identity):
            raise ValueError()
    except (ValueError, UnicodeError):
        raise HTTPException(422, "Invalid host identity") from None
    peer = hashlib.sha256((request.client.host if request.client else "unknown").encode()).hexdigest()
    now = int(time.time())
    try:
        with closing(database(write=True)) as conn, conn:
            conn.execute("BEGIN IMMEDIATE")
            conn.execute("DELETE FROM attempts WHERE hour < ?", (now // 3600,))
            if not conn.execute("SELECT 1 FROM attempts WHERE peer=?", (peer,)).fetchone() and conn.execute("SELECT COUNT(*) FROM attempts").fetchone()[0] >= 10000:
                raise HTTPException(503, "Registration window capacity reached")
            conn.execute("INSERT INTO attempts VALUES (?, ?, 1) ON CONFLICT(peer) DO UPDATE SET count=count+1", (peer, now // 3600))
            limited = conn.execute("SELECT count FROM attempts WHERE peer=?", (peer,)).fetchone()[0] > 60
            if not limited:
                exists = conn.execute("SELECT 1 FROM hosts WHERE identity=?", (identity,)).fetchone()
                if not exists and conn.execute("SELECT COUNT(*) FROM hosts").fetchone()[0] >= MAX_HOSTS:
                    raise HTTPException(503, "Registry capacity reached")
                conn.execute("INSERT OR IGNORE INTO hosts VALUES (?, ?)", (identity, now))
        if limited:
            raise HTTPException(429, "Registration limit reached", headers={"Retry-After": "3600"})
    except sqlite3.Error:
        raise HTTPException(503, "Registry unavailable") from None
    return JSONResponse({"registered": True}, headers={"Cache-Control": "no-store"})

if __name__ == "__main__":
    migrate(DATA)
