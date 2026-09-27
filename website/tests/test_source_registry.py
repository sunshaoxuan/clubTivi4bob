import json
import sqlite3
import sys
from pathlib import Path

from fastapi import FastAPI
from fastapi.testclient import TestClient

site = Path(__file__).parents[1]
sys.path.insert(0, str(site))
import source_registry as registry
sys.path.remove(str(site))

app = FastAPI()
app.include_router(registry.router)
client = TestClient(app)
SOURCE = {"id": "public-demo", "name": "公开演示", "url": "https://media.example.org/live.m3u8"}


def setup_catalog(tmp_path, monkeypatch, sources=None):
    monkeypatch.setattr(registry, "DATA", tmp_path)
    path = tmp_path / "sources.json"
    path.write_text(json.dumps({"sources": [SOURCE] if sources is None else sources}), encoding="utf-8")
    monkeypatch.setattr(registry, "CATALOG", path)
    registry.migrate(tmp_path / registry.REPORT_DB)
    registry.migrate(tmp_path / registry.REPORT_DB)


def report(fingerprint, playable=True, **extra):
    return {"sourceId": "public-demo", "fingerprint": fingerprint, "playable": playable, **extra}


def test_curated_catalog_and_migration(tmp_path, monkeypatch):
    setup_catalog(tmp_path, monkeypatch)
    response = client.get("/api/v1/sources")
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.json()["sources"] == [{**SOURCE, "feedback": {"recentPlayable": 0, "recentFailed": 0, "windowSeconds": 1800}}]
    with sqlite3.connect(tmp_path / registry.REPORT_DB) as conn:
        assert conn.execute("PRAGMA user_version").fetchone()[0] == 1
    (tmp_path / "sources.json").write_text('{"sources": []}', encoding="utf-8")
    assert client.get("/api/v1/sources").json() == {"sources": []}


def test_reports_are_bounded_deduplicated_and_expire(tmp_path, monkeypatch):
    setup_catalog(tmp_path, monkeypatch)
    now = 1_800_000_000
    monkeypatch.setattr(registry.time, "time", lambda: now)
    first = "a" * 64
    second = "b" * 64
    assert client.post("/api/v1/source-reports", json=report(first)).status_code == 202
    assert client.post("/api/v1/source-reports", json=report(first, False)).status_code == 202
    assert client.post("/api/v1/source-reports", json=report(second)).status_code == 202
    counts = client.get("/api/v1/sources").json()["sources"][0]["feedback"]
    assert (counts["recentPlayable"], counts["recentFailed"]) == (1, 1)
    with sqlite3.connect(tmp_path / registry.REPORT_DB) as conn:
        rows = conn.execute("SELECT reporter FROM reports").fetchall()
        assert len(rows) == 2
        assert all(first not in row[0] and second not in row[0] for row in rows)
    monkeypatch.setattr(registry.time, "time", lambda: now + 1801)
    assert client.get("/api/v1/sources").json()["sources"][0]["feedback"]["recentPlayable"] == 0


def test_reports_reject_unreviewed_urls_and_invalid_input(tmp_path, monkeypatch):
    setup_catalog(tmp_path, monkeypatch)
    fingerprint = "a" * 64
    assert client.post("/api/v1/source-reports", json=report(fingerprint, url="https://private.example/t?token=x")).status_code == 422
    assert client.post("/api/v1/source-reports", json=report(fingerprint, playable="yes")).status_code == 422
    assert client.post("/api/v1/source-reports", json=report("123e4567-e89b-42d3-a456-426614174000")).status_code == 422
    assert client.post("/api/v1/source-reports", json={**report(fingerprint), "sourceId": "unknown"}).status_code == 404
    assert client.post("/api/v1/source-reports", content=b"x" * 513, headers={"Content-Type": "application/json"}).status_code == 413
    assert client.post("/api/v1/source-reports", content=b"{}", headers={"Content-Type": "text/plain"}).status_code == 415
    with sqlite3.connect(tmp_path / registry.REPORT_DB) as conn:
        assert conn.execute("SELECT count(*) FROM reports").fetchone()[0] == 0


def test_report_rate_limit(tmp_path, monkeypatch):
    setup_catalog(tmp_path, monkeypatch)
    now = 1_800_000_000
    monkeypatch.setattr(registry.time, "time", lambda: now)
    origin_hash = registry.hashlib.sha256(f"{now // 86400}:testclient".encode()).hexdigest()
    with sqlite3.connect(tmp_path / registry.REPORT_DB) as conn:
        conn.execute("INSERT INTO rate_limits VALUES (?, ?, ?)", (origin_hash, now // 3600, 3600))
    response = client.post("/api/v1/source-reports", json=report("a" * 64))
    assert response.status_code == 429
    assert response.headers["retry-after"] == "3600"
    with sqlite3.connect(tmp_path / registry.REPORT_DB) as conn:
        assert conn.execute("SELECT count(*) FROM reports").fetchone()[0] == 0


def test_catalog_rejects_private_or_tokenized_urls(tmp_path, monkeypatch):
    for url in ("http://media.example.org/a.m3u8", "https://127.0.0.1/live", "https://media.example.org/live?token=x", "https://user:pass@media.example.org/live"):
        setup_catalog(tmp_path, monkeypatch, [{**SOURCE, "url": url}])
        try:
            registry._catalog()
        except ValueError:
            pass
        else:
            raise AssertionError(f"Accepted unreviewed URL: {url}")
