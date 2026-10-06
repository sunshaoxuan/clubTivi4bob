import sqlite3
import sys
from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi.testclient import TestClient
from test_bobtv_site import module

registry = sys.modules["device_registry"]
localization = sys.modules["localization"]

@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(registry, "DATA", tmp_path)
    monkeypatch.setattr(localization, "DATA", tmp_path)
    registry.migrate(tmp_path)
    return TestClient(module.app)

def test_idempotent_migration_and_same_host_registration(client, tmp_path):
    identity = "bth1_" + "a" * 64
    def register(_):
        return client.post("/api/v1/devices/register", json={"hostFingerprint": identity}).status_code
    with ThreadPoolExecutor(max_workers=4) as pool:
        assert list(pool.map(register, range(12))) == [200] * 12
    registry.migrate(tmp_path)
    assert client.get("/api/v1/devices/count").json() == {"count": 1}
    assert client.post("/api/v1/devices/register", json={"hostFingerprint": "bth1_" + "b" * 64}).status_code == 200
    assert client.get("/api/v1/devices/count").json() == {"count": 2}
    assert identity not in client.get("/").text

def test_legacy_installations_are_not_host_evidence(client, tmp_path):
    with sqlite3.connect(tmp_path / "channel_inventory.sqlite3") as conn:
        conn.execute("CREATE TABLE limits (reporter TEXT PRIMARY KEY)")
        conn.executemany("INSERT INTO limits VALUES (?)", [(str(i),) for i in range(45)])
    assert registry.installed_device_count() == 0

def test_corrupt_registry_fails_closed_without_changing_data(tmp_path, monkeypatch):
    monkeypatch.setattr(registry, "DATA", tmp_path)
    path = tmp_path / "device_registry.sqlite3"
    path.write_bytes(b"invalid sqlite data")
    assert registry.installed_device_count() is None
    assert path.read_bytes() == b"invalid sqlite data"
    assert TestClient(module.app).get("/api/v1/devices/count").status_code == 503

def test_migration_rejects_future_schema_without_modification(tmp_path):
    path = tmp_path / "device_registry.sqlite3"
    with sqlite3.connect(path) as conn:
        conn.execute("PRAGMA user_version=2")
    before = path.read_bytes()
    with pytest.raises(ValueError):
        registry.migrate(tmp_path)
    assert path.read_bytes() == before

def test_missing_database_is_unknown_and_not_created(tmp_path, monkeypatch):
    monkeypatch.setattr(registry, "DATA", tmp_path)
    monkeypatch.setattr(localization, "DATA", tmp_path)
    assert registry.installed_device_count() is None
    response = TestClient(module.app).get("/api/v1/devices/count")
    assert response.status_code == 503 and response.json() == {"count": None}
    assert not list(tmp_path.iterdir())
    assert 'id="installed-devices"></span>' in TestClient(module.app).get("/").text

@pytest.mark.parametrize("payload", [None, [], {}, {"hostFingerprint": 1},
    {"hostFingerprint": "a" * 64}, {"hostFingerprint": "bth1_" + "A" * 64},
    {"hostFingerprint": "bth1_" + "a" * 64, "uuid": "raw"}])
def test_registration_strict_schema(client, payload):
    import json
    assert client.post("/api/v1/devices/register", content=json.dumps(payload),
                       headers={"Content-Type": "application/json"}).status_code == 422
    assert registry.installed_device_count() == 0

def test_bounds_and_rate_limit(client):
    assert client.post("/api/v1/devices/register", content="x").status_code == 415
    assert client.post("/api/v1/devices/register", content="x" * 257,
                       headers={"Content-Type": "application/json"}).status_code == 413
    for _ in range(60):
        assert client.post("/api/v1/devices/register", json={"hostFingerprint": "bth1_" + "c" * 64}).status_code == 200
    response = client.post("/api/v1/devices/register", json={"hostFingerprint": "bth1_" + "d" * 64})
    assert response.status_code == 429 and response.headers["retry-after"] == "3600"
    assert registry.installed_device_count() == 1

def test_capacity_and_missing_schema(client, monkeypatch, tmp_path):
    monkeypatch.setattr(registry, "MAX_HOSTS", 1)
    assert client.post("/api/v1/devices/register", json={"hostFingerprint": "bth1_" + "a" * 64}).status_code == 200
    assert client.post("/api/v1/devices/register", json={"hostFingerprint": "bth1_" + "b" * 64}).status_code == 503
    assert client.post("/api/v1/devices/register", json={"hostFingerprint": "bth1_" + "a" * 64}).status_code == 200
    monkeypatch.setattr(registry, "DATA", tmp_path / "missing")
    assert client.post("/api/v1/devices/register", json={"hostFingerprint": "bth1_" + "a" * 64}).status_code == 503

@pytest.mark.parametrize("locale", ["en", "ja", "zh-CN", "zh-TW"])
@pytest.mark.parametrize("path", ["/", "/downloads", "/diagnostics"])
def test_footer_count_and_live_endpoint(client, locale, path):
    assert 'id="installed-devices"> (0)</span>' in client.get(path, params={"lang": locale}).text
    client.post("/api/v1/devices/register", json={"hostFingerprint": "bth1_" + "b" * 64})
    html = client.get(path, params={"lang": locale}).text
    assert 'id="installed-devices"> (1)</span>' in html
    assert "/assets/device-count.js?v=1" in html
    assert client.get("/api/v1/devices/count").headers["cache-control"] == "no-store"
