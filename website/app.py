"""BobTV public site and bounded diagnostic ingestion."""

import hashlib
import json
import os
import re
import sqlite3
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from source_registry import router as source_router
from source_candidates import router as candidate_router
from channel_catalog import router as catalog_router

BASE = Path(__file__).resolve().parent
DATA = Path(os.environ.get("BOBTV_DATA_DIR", BASE / "data"))
MAX_LOG = 1024 * 1024
MAX_STORAGE = 512 * 1024 * 1024
RETENTION_SECONDS = 14 * 86400
ALLOWED_FIELDS = {"time", "event", "source", "fatal", "uptimeSeconds", "rssBytes", "maxRssBytes", "platform"}
ID_PATTERN = re.compile(r"^[a-f0-9]{32}$")
app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
app.include_router(source_router)
app.include_router(candidate_router)
app.include_router(catalog_router)
app.mount("/assets", StaticFiles(directory=BASE / "assets"), name="assets")


def _database():
    DATA.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DATA / "logs.sqlite3", timeout=10)
    conn.execute("CREATE TABLE IF NOT EXISTS uploads (digest TEXT PRIMARY KEY, received INTEGER NOT NULL, size INTEGER NOT NULL, source TEXT NOT NULL)")
    conn.execute("CREATE TABLE IF NOT EXISTS attempts (client TEXT PRIMARY KEY, window INTEGER NOT NULL, count INTEGER NOT NULL)")
    return conn


def _prune(conn, now):
    stale = conn.execute("SELECT digest FROM uploads WHERE received < ?", (now - RETENTION_SECONDS,)).fetchall()
    for (digest,) in stale:
        (DATA / "uploads" / f"{digest}.log").unlink(missing_ok=True)
    conn.execute("DELETE FROM uploads WHERE received < ?", (now - RETENTION_SECONDS,))
    conn.execute("DELETE FROM attempts WHERE window < ?", (now // 3600 - 1,))


@app.api_route("/", methods=["GET", "HEAD"])
def home():
    return FileResponse(BASE / "index.html")


@app.api_route("/downloads", methods=["GET", "HEAD"])
def downloads_page():
    return FileResponse(BASE / "downloads.html")


@app.api_route("/diagnostics", methods=["GET", "HEAD"])
def diagnostics_page():
    return FileResponse(BASE / "diagnostics.html")


@app.api_route("/releases.json", methods=["GET", "HEAD"])
def releases():
    path = DATA / "releases.json"
    if not path.exists():
        return JSONResponse({"releases": []}, headers={"Cache-Control": "no-store"})
    return FileResponse(path, media_type="application/json", headers={"Cache-Control": "no-store"})


@app.api_route("/downloads/{filename}", methods=["GET", "HEAD"])
def download(filename: str):
    manifest = DATA / "releases.json"
    if not manifest.exists():
        raise HTTPException(404)
    releases = json.loads(manifest.read_text(encoding="utf-8")).get("releases", [])
    if not any(item.get("filename") == filename for item in releases):
        raise HTTPException(404)
    path = DATA / "releases" / filename
    if not path.is_file():
        raise HTTPException(404)
    return FileResponse(path, filename=filename, media_type="application/zip")


@app.post("/api/v1/logs")
async def upload(request: Request):
    kind = request.headers.get("content-type", "").split(";", 1)[0]
    if kind != "application/x-ndjson":
        raise HTTPException(415, "Expected application/x-ndjson")
    declared = request.headers.get("content-length")
    if declared and declared.isdecimal() and int(declared) > MAX_LOG:
        raise HTTPException(413, "Log exceeds 1 MiB")
    client = request.client.host if request.client else "unknown"
    now = int(time.time())
    with _database() as conn:
        _prune(conn, now)
        window = now // 3600
        row = conn.execute("SELECT window, count FROM attempts WHERE client = ?", (client,)).fetchone()
        count = row[1] + 1 if row and row[0] == window else 1
        conn.execute("INSERT INTO attempts VALUES (?, ?, ?) ON CONFLICT(client) DO UPDATE SET window=excluded.window, count=excluded.count", (client, window, count))
        if count > 300:
            raise HTTPException(429, "Hourly upload limit reached", headers={"Retry-After": "3600"})

    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > MAX_LOG:
            raise HTTPException(413, "Log exceeds 1 MiB")
    try:
        content = body.decode("utf-8")
        lines = content.splitlines()
        if not lines or len(lines) > 5000:
            raise ValueError("Invalid number of entries")
        for line in lines:
            if len(line) > 4096:
                raise ValueError("Entry exceeds 4096 characters")
            entry = json.loads(line)
            if not isinstance(entry, dict) or not {"time", "event"} <= entry.keys() or not entry.keys() <= ALLOWED_FIELDS:
                raise ValueError("Unexpected diagnostic fields")
            if not all(isinstance(value, (str, int, float, bool)) and (not isinstance(value, str) or len(value) <= 256) for value in entry.values()):
                raise ValueError("Invalid diagnostic value")
    except (UnicodeError, ValueError, json.JSONDecodeError) as exc:
        raise HTTPException(422, "Invalid diagnostic JSONL") from exc

    digest = hashlib.sha256(body).hexdigest()
    with _database() as conn:
        existing = conn.execute("SELECT 1 FROM uploads WHERE digest = ?", (digest,)).fetchone()
        if existing:
            return JSONResponse({"id": digest, "duplicate": True}, status_code=200)
        used = conn.execute("SELECT COALESCE(SUM(size), 0) FROM uploads").fetchone()[0]
        if used + len(body) > MAX_STORAGE:
            raise HTTPException(503, "Diagnostic storage is full", headers={"Retry-After": "3600"})
        folder = DATA / "uploads"
        folder.mkdir(parents=True, exist_ok=True)
        tmp = folder / f"{digest}.{os.getpid()}.tmp"
        tmp.write_bytes(body)
        os.replace(tmp, folder / f"{digest}.log")
        conn.execute("INSERT OR IGNORE INTO uploads VALUES (?, ?, ?, ?)", (digest, now, len(body), "client"))
    return JSONResponse({"id": digest, "duplicate": False}, status_code=201)
