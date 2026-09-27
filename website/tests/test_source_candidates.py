import json
import sqlite3
import sys
from pathlib import Path

from fastapi import FastAPI
from fastapi.testclient import TestClient

site = Path(__file__).parents[1]
sys.path.insert(0, str(site))
import source_candidates as candidates
sys.path.remove(str(site))

app = FastAPI()
app.include_router(candidates.router)
URL = "https://media.example.org/live.m3u8"
FINGERPRINT = "a" * 64


def setup_database(tmp_path, monkeypatch):
    monkeypatch.setattr(candidates, "DATA", tmp_path)
    candidates.migrate(tmp_path / candidates.DATABASE)
    candidates.migrate(tmp_path / candidates.DATABASE)


def payload(**changes):
    return {"name": "公开频道", "url": URL, "device": "Windows", "fingerprint": FINGERPRINT, "consent": True, **changes}


def test_contribution_records_trusted_attribution_privately(tmp_path, monkeypatch):
    setup_database(tmp_path, monkeypatch)
    now = 1_800_000_000
    monkeypatch.setattr(candidates.time, "time", lambda: now)
    client = TestClient(app, client=("172.71.8.140", 1234))
    headers = {"CF-Connecting-IP": "198.51.100.42", "CF-IPCountry": "JP"}
    for _ in range(2):
        assert client.post("/api/v1/source-candidates", json=payload(), headers=headers).status_code == 202
    with sqlite3.connect(tmp_path / candidates.DATABASE) as conn:
        row = conn.execute("SELECT name, url, ip, device, country FROM candidates").fetchone()
        assert row == ("公开频道", URL, "198.51.100.42", "Windows", "JP")
        assert conn.execute("SELECT count(*) FROM candidates").fetchone()[0] == 1
        assert conn.execute("SELECT client_hash FROM candidates").fetchone()[0] == candidates.hashlib.sha256(FINGERPRINT.encode()).hexdigest()
        assert conn.execute("PRAGMA user_version").fetchone()[0] == 1
    assert client.get("/api/v1/source-contributions/summary").status_code == 404
    assert client.get("/api/v1/source-candidates/private").status_code == 404
    monkeypatch.setattr(candidates.time, "time", lambda: now + candidates.RETENTION + 1)
    with sqlite3.connect(tmp_path / candidates.DATABASE) as conn:
        candidates.prune(conn, int(candidates.time.time()))
        assert conn.execute("SELECT count(*) FROM candidates").fetchone()[0] == 0


def test_direct_origin_cannot_spoof_country_or_ip(tmp_path, monkeypatch):
    setup_database(tmp_path, monkeypatch)
    client = TestClient(app, client=("203.0.113.7", 1234))
    response = client.post("/api/v1/source-candidates", json=payload(), headers={"CF-Connecting-IP": "198.51.100.42", "CF-IPCountry": "US"})
    assert response.status_code == 202
    with sqlite3.connect(tmp_path / candidates.DATABASE) as conn:
        assert conn.execute("SELECT ip, country FROM candidates").fetchone() == ("203.0.113.7", None)


def test_client_identity_survives_ip_change(tmp_path, monkeypatch):
    setup_database(tmp_path, monkeypatch)
    for ip in ("203.0.113.7", "203.0.113.8"):
        client = TestClient(app, client=(ip, 1234))
        assert client.post("/api/v1/source-candidates", json=payload()).status_code == 202
    with sqlite3.connect(tmp_path / candidates.DATABASE) as conn:
        assert conn.execute("SELECT count(*) FROM candidates").fetchone()[0] == 1
        assert conn.execute("SELECT ip FROM candidates").fetchone()[0] == "203.0.113.8"


def test_candidate_requires_consent_and_public_url(tmp_path, monkeypatch):
    setup_database(tmp_path, monkeypatch)
    client = TestClient(app)
    for bad in (
        payload(consent=False), payload(url="http://media.example.org/live"),
        payload(url="https://127.0.0.1/live"), payload(url="https://media.example.org/live?token=secret"),
        payload(device="serial-123"), {**payload(), "password": "secret"},
        payload(fingerprint="123e4567-e89b-42d3-a456-426614174000"),
    ):
        assert client.post("/api/v1/source-candidates", json=bad).status_code == 422
    assert client.post("/api/v1/source-candidates", content=b"x" * 4097, headers={"Content-Type": "application/json"}).status_code == 413
    assert client.post("/api/v1/source-candidates", content=b"{}", headers={"Content-Type": "text/plain"}).status_code == 415
    with sqlite3.connect(tmp_path / candidates.DATABASE) as conn:
        assert conn.execute("SELECT count(*) FROM candidates").fetchone()[0] == 0


def test_distinct_fingerprints_and_rate_limits(tmp_path, monkeypatch):
    setup_database(tmp_path, monkeypatch)
    now = 1_800_000_000
    monkeypatch.setattr(candidates.time, "time", lambda: now)
    for i in range(3):
        client = TestClient(app, client=("172.71.8.140", 1234))
        assert client.post("/api/v1/source-candidates", json=payload(url=f"https://media.example.org/live{i}.m3u8", fingerprint=f"{i + 1:064x}"), headers={"CF-Connecting-IP": f"198.51.100.{i + 1}", "CF-IPCountry": "JP"}).status_code == 202
    with sqlite3.connect(tmp_path / candidates.DATABASE) as conn:
        assert conn.execute("SELECT count(DISTINCT client_hash) FROM candidates").fetchone()[0] == 3
    origin = candidates.hashlib.sha256(f"{now // 86400}:198.51.100.3".encode()).hexdigest()
    with sqlite3.connect(tmp_path / candidates.DATABASE) as conn:
        conn.execute("UPDATE rate_limits SET count = 30 WHERE origin = ?", (origin,))
    response = client.post("/api/v1/source-candidates", json=payload(url="https://media.example.org/another.m3u8"), headers={"CF-Connecting-IP": "198.51.100.3", "CF-IPCountry": "JP"})
    assert response.status_code == 429
    assert response.headers["retry-after"] == "3600"
