import importlib.util
import json
import sys
import time
from pathlib import Path

from fastapi.testclient import TestClient

site = Path(__file__).parents[1]
sys.path.insert(0, str(site))
spec = importlib.util.spec_from_file_location("bobtv_app", site / "app.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
sys.path.remove(str(site))


def test_upload_validates_bounds_and_deduplicates(tmp_path, monkeypatch):
    monkeypatch.setattr(module, "DATA", tmp_path)
    client = TestClient(module.app)
    body = b'{"time":"2026-09-27T00:00:00Z","event":"heartbeat","rssBytes":123}\n'
    headers = {"Content-Type": "application/x-ndjson"}
    first = client.post("/api/v1/logs", content=body, headers=headers)
    assert first.status_code == 201
    assert client.post("/api/v1/logs", content=body, headers=headers).json()["duplicate"] is True
    assert len(list((tmp_path / "uploads").glob("*.log"))) == 1
    assert client.post("/api/v1/logs", content=b'{"time":"x","event":"y","password":"secret"}\n', headers=headers).status_code == 422
    assert client.post("/api/v1/logs", content=b"x" * (module.MAX_LOG + 1), headers=headers).status_code == 413
    assert client.post("/api/v1/logs", content=body).status_code == 415
    for _ in range(297):
        assert client.post("/api/v1/logs", content=body, headers=headers).status_code == 200
    limited = client.post("/api/v1/logs", content=body, headers=headers)
    assert limited.status_code == 429
    assert limited.headers["retry-after"] == "3600"


def test_site_download_is_local_and_manifest_gated(tmp_path, monkeypatch):
    monkeypatch.setattr(module, "DATA", tmp_path)
    (tmp_path / "releases").mkdir()
    (tmp_path / "releases" / "BobTV.zip").write_bytes(b"PK\x03\x04demo")
    (tmp_path / "releases.json").write_text(json.dumps({"releases": [{"filename": "BobTV.zip"}]}))
    client = TestClient(module.app)
    response = client.get("/downloads/BobTV.zip")
    assert response.content == b"PK\x03\x04demo"
    assert "location" not in response.headers
    partial = client.get("/downloads/BobTV.zip", headers={"Range": "bytes=0-3"})
    assert partial.status_code == 206
    assert partial.content == b"PK\x03\x04"
    assert client.get("/downloads/other.zip").status_code == 404
    assert client.get("/").status_code == 200
    assert client.head("/").status_code == 200
    assert client.get("/downloads").status_code == 200
    assert client.get("/reports").status_code == 404
    assert client.get("/diagnostics").status_code == 200
    assert client.head("/downloads/BobTV.zip").headers["content-length"] == "8"


def test_product_pages_reflect_published_releases():
    client = TestClient(module.app)
    home = client.get("/").text
    assert "v0.9.1-bob.17" in home and "WINDOWS · MACOS" in home
    assert "更新进度可见" in home and "退出后继续显示备份、安装及完成状态" in home
    assert "静音预览" in home and "Mac AirPlay" in home and "纯音频电台" in home
    assert '/assets/product.png?v=3' in home
    assert 'class="home-page"' in home and 'class="container home-hero-layout"' in home
    assert 'href="/downloads"' in home and 'href="/diagnostics"' in home
    assert "github.com" not in home.lower()
    downloads = client.get("/downloads").text
    assert 'id="release-list"' in downloads and "BobTV.exe" in downloads
    assert "Apple Silicon" in downloads and "下载最新版本" in downloads
    assert "v0.9.1-bob.11" not in downloads
    assert 'class="downloads-page"' in downloads
    script = client.get("/assets/downloads.js").text
    assert "release.version === latest.version" in script
    assert script.count("{ name: '") == 3
    diagnostics = client.get("/diagnostics").text
    assert 'class="diagnostics-page"' in diagnostics
    assert 'id="upload-form"' in diagnostics and 'id="log-file"' in diagnostics


def test_expired_diagnostics_are_removed(tmp_path, monkeypatch):
    monkeypatch.setattr(module, "DATA", tmp_path)
    folder = tmp_path / "uploads"
    folder.mkdir()
    (folder / ("a" * 64 + ".log")).write_bytes(b"old")
    with module._database() as connection:
        connection.execute("INSERT INTO uploads VALUES (?, ?, ?, ?)", ("a" * 64, int(time.time()) - module.RETENTION_SECONDS - 1, 3, "client"))
        module._prune(connection, int(time.time()))
        assert connection.execute("SELECT count(*) FROM uploads").fetchone()[0] == 0
    assert not list(folder.iterdir())
