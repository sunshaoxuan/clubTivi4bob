import gzip
import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parents[1]))
from catalog_inventory import ingest, database
from process_channel_inventory import process, _identity
import catalog_inventory
from fastapi import FastAPI
from fastapi.testclient import TestClient


def route(name="CCTV-5+", url="https://media.example.org/live.m3u8", blocked=False):
    return {"name": name, "url": url, "group": "中国 / 央视",
            "source": "test-provider", "blocked": blocked, "playableAt": None}


def snapshot(data):
    manifest = json.loads((data / "channel-catalog/manifest.json").read_text())
    return json.loads(gzip.decompress((data / "channel-catalog/snapshots" /
        (manifest["sha256"] + ".json.gz")).read_bytes()))


def test_verification_then_publication(tmp_path):
    receipt = ingest([route()], "a" * 64, tmp_path)
    assert receipt["storedRoutes"] == 1
    assert not (tmp_path / "channel-catalog/manifest.json").exists()
    assert process(tmp_path, verifier=lambda url: True)["published"]
    assert snapshot(tmp_path)["channels"][0]["name"] == "CCTV-5+"
    assert snapshot(tmp_path)["channels"][0]["routes"][0]["lastPlayableAt"]
    assert ingest([route()], "b" * 64, tmp_path)["storedRoutes"] == 1


def test_retirement_propagates_and_cannot_be_reintroduced(tmp_path):
    ingest([route(), route("CCTV-1", "https://media.example.org/one.m3u8")], "a" * 64, tmp_path)
    process(tmp_path, verifier=lambda url: True)
    ingest([route(blocked=True)], "b" * 64, tmp_path)
    ingest([route()], "c" * 64, tmp_path)
    process(tmp_path, verifier=lambda url: True)
    assert [c["name"] for c in snapshot(tmp_path)["channels"]] == ["CCTV-1"]
    with database(tmp_path) as conn:
        assert conn.execute("SELECT blocked FROM routes WHERE name='CCTV-5+' ").fetchone()[0] == 1


def test_invalid_routes_are_skipped(tmp_path):
    result = ingest([route(url="http://127.0.0.1/private"),
        route(url="https://media.example.org/live?token=secret"),
        route(url="https://media.example.org/live/user/password/1.ts"),
        route(url="http://38.75.136.137:8080/live")], "a" * 64, tmp_path)
    assert result["accepted"] == 1
    assert result["skipped"] == 3


def test_distinct_cctv_signals():
    assert _identity("CCTV5 体育") == "CCTV-5"
    assert _identity("CCTV5+ 体育赛事") == "CCTV-5+"
    assert _identity("CCTV5 4K") == "CCTV-5 4K"


def test_catalog_preserves_logo_and_epg_metadata(tmp_path):
    item = route()
    item.update(logoUrl="https://logos.example.org/cctv5plus.png", epgId="cctv5plus")
    ingest([item], "a" * 64, tmp_path)
    process(tmp_path, verifier=lambda url: True)
    channel = snapshot(tmp_path)["channels"][0]
    assert channel["logoUrl"] == item["logoUrl"]
    assert channel["epgId"] == item["epgId"]


def test_webpage_routes_do_not_poison_the_whole_shared_catalog(tmp_path):
    ingest([route(), route("Web page", "https://media.example.org/watch.html")], "a" * 64, tmp_path)
    process(tmp_path, verifier=lambda url: True)
    assert [channel["name"] for channel in snapshot(tmp_path)["channels"]] == ["CCTV-5+"]


def test_non_television_candidates_never_enter_shared_snapshot(tmp_path):
    ingest([route(), route("购物", "https://media.example.org/shop.m3u8"),
        route("Live room", "https://live.huya.com/watch.m3u8")], "a" * 64, tmp_path)
    process(tmp_path, verifier=lambda url: True)
    assert [channel["name"] for channel in snapshot(tmp_path)["channels"]] == ["CCTV-5+"]


def test_inventory_api_and_global_tombstones(tmp_path, monkeypatch):
    monkeypatch.setattr(catalog_inventory, "DATA", tmp_path)
    app = FastAPI()
    app.include_router(catalog_inventory.router)
    client = TestClient(app)
    body = {"schemaVersion": 1, "fingerprint": "a" * 64,
            "routes": [route(blocked=True)]}
    assert client.post("/api/v1/channel-catalog/inventory", json=body).status_code == 202
    assert client.get("/api/v1/channel-catalog/blocked").json()["urls"] == [route()["url"]]
    body["fingerprint"] = 123
    assert client.post("/api/v1/channel-catalog/inventory", json=body).status_code == 422
    assert client.post("/api/v1/channel-catalog/inventory", content=b"x" * (512 * 1024 + 1),
        headers={"content-type": "application/json"}).status_code == 413
