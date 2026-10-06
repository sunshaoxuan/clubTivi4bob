import hashlib
import sqlite3
import sys

import pytest
from fastapi.testclient import TestClient

from test_bobtv_site import module

localization = sys.modules["localization"]
inventory = sys.modules["catalog_inventory"]


def test_existing_inventory_deduplicates_repeated_client_fingerprints(tmp_path, monkeypatch):
    monkeypatch.setattr(localization, "DATA", tmp_path)
    route = {"name": "Demo", "url": "https://media.example.org/live.m3u8",
             "group": "Demo", "source": "demo", "blocked": False}
    fingerprint = "a" * 64
    inventory.ingest([route], fingerprint, tmp_path)
    inventory.ingest([route], fingerprint, tmp_path)
    assert localization.installed_device_count() == 1
    inventory.ingest_events([{"id": "d" * 16, "url": route["url"],
                             "kind": "health", "success": 1}], fingerprint, tmp_path)
    assert localization.installed_device_count() == 1
    inventory.ingest([route], "b" * 64, tmp_path)
    assert localization.installed_device_count() == 2
    assert hashlib.sha256(fingerprint.encode()).hexdigest() not in TestClient(module.app).get("/").text


def test_count_is_cumulative_even_after_batch_expiry(tmp_path, monkeypatch):
    monkeypatch.setattr(localization, "DATA", tmp_path)
    with inventory.database(tmp_path) as conn:
        conn.execute("INSERT INTO limits VALUES (?,0,1)", ("a" * 64,))
        conn.execute("INSERT INTO batches VALUES (?,?,0)", ("a" * 64, "b" * 64))
        conn.execute("DELETE FROM batches")
    assert localization.installed_device_count() == 1


def test_missing_database_is_unknown_and_not_created(tmp_path, monkeypatch):
    monkeypatch.setattr(localization, "DATA", tmp_path)
    assert localization.installed_device_count() is None
    assert not list(tmp_path.iterdir())
    html = TestClient(module.app).get("/?lang=en").text
    assert "Open-source desktop player (0)" not in html
    assert "Open-source desktop player</span>" in html


def test_unreadable_schema_does_not_change_database(tmp_path, monkeypatch):
    monkeypatch.setattr(localization, "DATA", tmp_path)
    path = tmp_path / "channel_inventory.sqlite3"
    with sqlite3.connect(path) as conn:
        conn.execute("CREATE TABLE unrelated (value INTEGER)")
    before = path.read_bytes()
    assert localization.installed_device_count() is None
    assert path.read_bytes() == before


@pytest.mark.parametrize("locale", ["en", "ja", "zh-CN", "zh-TW"])
@pytest.mark.parametrize("path", ["/", "/downloads", "/diagnostics"])
def test_footer_contains_only_integer_in_parentheses(tmp_path, monkeypatch, locale, path):
    monkeypatch.setattr(localization, "DATA", tmp_path)
    with sqlite3.connect(tmp_path / "channel_inventory.sqlite3") as conn:
        conn.execute("CREATE TABLE limits (reporter TEXT PRIMARY KEY, hour INTEGER, count INTEGER)")
    client = TestClient(module.app)
    assert f'{localization.COPY[locale]["footer"]} (0)</span>' in client.get(path, params={"lang": locale}).text
    with sqlite3.connect(tmp_path / "channel_inventory.sqlite3") as conn:
        conn.executemany("INSERT INTO limits VALUES (?,0,1)", [("a" * 64,), ("b" * 64,)])
    response = client.get(path, params={"lang": locale})
    head = client.head(path, params={"lang": locale})
    assert f'{localization.COPY[locale]["footer"]} (2)</span>' in response.text
    assert 'a' * 64 not in response.text
    assert head.status_code == 200 and head.content == b""
    assert head.headers["content-length"] == response.headers["content-length"]
