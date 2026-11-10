import gzip
import importlib.util
import json
import re
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

site = Path(__file__).parents[1]
sys.path.insert(0, str(site))
import channel_catalog
from publish_channel_catalog import publish
spec = importlib.util.spec_from_file_location("bobtv_catalog_app", site / "app.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
sys.path.remove(str(site))


def example():
    return {
        "schemaVersion": 1,
        "version": "2026-09-28.1",
        "categories": [
            {"id": "cn", "parentId": None, "name": "中国", "sortOrder": 1},
            {"id": "cn-cctv", "parentId": "cn", "name": "央视", "sortOrder": 1},
        ],
        "channels": [{
            "id": "cctv-5-plus", "name": "CCTV-5+", "categoryId": "cn-cctv",
            "countryCode": "CN", "regionCode": None, "sortOrder": 25,
            "epgId": "cctv5plus", "logoUrl": None,
            "routes": [{
                "id": "route-one", "url": "https://media.example.org/live.m3u8",
                "source": "reviewed", "lastPlayableAt": None, "healthScore": 0.7,
            }],
        }],
    }


def test_empty_manifest_is_safe(tmp_path, monkeypatch):
    monkeypatch.setattr(channel_catalog, "DATA", tmp_path)
    client = TestClient(module.app)
    response = client.get("/api/v1/channel-catalog/manifest")
    assert response.status_code == 200
    assert response.json()["channelCount"] == 0
    assert client.get("/api/v1/channel-catalog/snapshots/" + "a" * 64 + ".json.gz").status_code == 404


def test_publish_serves_immutable_snapshot(tmp_path, monkeypatch):
    monkeypatch.setattr(channel_catalog, "DATA", tmp_path)
    metadata = publish(example(), tmp_path)
    client = TestClient(module.app)
    manifest = client.get("/api/v1/channel-catalog/manifest")
    assert manifest.json() == metadata
    assert client.get("/api/v1/channel-catalog/manifest", headers={"If-None-Match": manifest.headers["etag"]}).status_code == 304
    snapshot = client.get(metadata["snapshotUrl"])
    assert snapshot.status_code == 200
    assert json.loads(gzip.decompress(snapshot.content)) == example()
    assert snapshot.headers["cache-control"].endswith("immutable")
    next_catalog = example()
    next_catalog["version"] = "2026-09-28.2"
    publish(next_catalog, tmp_path)
    assert client.get(metadata["snapshotUrl"]).status_code == 200
    assert client.get("/api/v1/channel-catalog/snapshots/" + "b" * 64 + ".json.gz").status_code == 404


def test_invalid_publication_does_not_replace_manifest(tmp_path):
    first = publish(example(), tmp_path)
    invalid = example()
    invalid["channels"][0]["routes"][0]["url"] = "https://127.0.0.1/private"
    with pytest.raises(ValueError):
        publish(invalid, tmp_path)
    assert json.loads((tmp_path / "channel-catalog" / "manifest.json").read_text()) == first
    invalid = example()
    invalid["channels"][0]["routes"].append(dict(invalid["channels"][0]["routes"][0]))
    with pytest.raises(ValueError, match="Duplicate"):
        publish(invalid, tmp_path)
    invalid = example()
    invalid["channels"][0]["logoUrl"] = "https://127.0.0.1/logo.png"
    with pytest.raises(ValueError):
        publish(invalid, tmp_path)


def test_homepage_figures_follow_each_published_catalog(tmp_path, monkeypatch):
    monkeypatch.setattr(channel_catalog, "DATA", tmp_path)
    payload = example()
    payload["categories"] += [
        {"id": "radio", "parentId": "cn", "name": "广播", "sortOrder": 2},
        {"id": "news", "parentId": "cn", "name": "新闻", "sortOrder": 3},
        {"id": "web", "parentId": None, "name": "网络直播", "sortOrder": 4},
        {"id": "web-entertainment", "parentId": "web", "name": "娱乐", "sortOrder": 5},
        {"id": "radio-news", "parentId": "radio", "name": "新闻", "sortOrder": 6},
    ]

    def add_channel(name, category, country):
        payload["channels"].append({
            **payload["channels"][0], "id": name, "name": name,
            "categoryId": category, "countryCode": country, "epgId": None,
            "routes": [{**payload["channels"][0]["routes"][0],
                        "id": name + "-route", "url": f"https://media.example.org/{name}.m3u8"}],
        })

    add_channel("radio-one", "radio-news", "CN")
    publish(payload, tmp_path)
    client = TestClient(module.app)

    def figures():
        response = client.get("/?lang=zh-CN")
        assert response.status_code == 200
        return list(map(int, re.findall(r'data-count-to="(\d+)"', response.text)))

    assert figures() == [1, 7, 1, 1, 0, 0, 0, 0, 0]
    payload["version"] = "2026-09-28.2"
    add_channel("news-one", "news", "JP")
    add_channel("web-one", "web-entertainment", "JP")
    publish(payload, tmp_path)
    assert figures() == [2, 7, 2, 1, 0, 1, 0, 0, 0]
