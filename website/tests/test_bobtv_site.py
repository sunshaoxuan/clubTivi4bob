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


def test_setup_download_is_manifest_gated_and_has_binary_mime(tmp_path, monkeypatch):
    monkeypatch.setattr(module, "DATA", tmp_path)
    folder = tmp_path / "releases"
    folder.mkdir()
    name = "BobTV-0.9.1+80-windows-x64-Setup.exe"
    (folder / name).write_bytes(b"MZsetup")
    (tmp_path / "releases.json").write_text(json.dumps({"releases": [{"filename": name}]}))
    client = TestClient(module.app)
    response = client.get("/downloads/" + name)
    assert response.status_code == 200
    assert response.headers["content-type"] == "application/octet-stream"
    assert response.content == b"MZsetup"
    assert client.get("/downloads/unlisted-Setup.exe").status_code == 404


def test_product_pages_reflect_published_releases():
    client = TestClient(module.app)
    home = client.get("/?lang=zh-CN").text
    version = next(line.split(':', 1)[1].strip()
                   for line in (site.parent / 'pubspec.yaml').read_text().splitlines()
                   if line.startswith('version:'))
    history = client.get("/release-notes?lang=zh-CN").text
    header, _, footer = home.partition("<footer>")
    assert 'class="history-band"' not in home
    assert 'href="/release-notes"' not in header and 'href="/diagnostics"' not in header
    assert '<a href="/release-notes">版本记录</a>' in footer
    assert '<a href="/diagnostics">上传日志</a>' in footer
    assert '<a href="/release-notes" aria-current="page">版本记录</a>' in history
    assert "v1.0.3" in history and "v1.0.5 · 服务器链路、频道合并与全屏修复" in history
    assert "桌面画中画与全屏节目单" in history
    assert "100 多个国家" in home and "七种界面语言" in home
    assert "iPhone、iPad 和嵌入式网页播放器正在开发" in home
    assert "部分频道" in home and "质量差的线路可以淘汰" in home
    assert '/assets/product.png?v=3' in home
    assert '/assets/showcase/hero.webp' in home
    assert 'class="home-page"' in home and 'class="container home-hero-layout"' in home
    assert 'href="/downloads"' in header and 'class="back-top"' in home
    assert 'class="back-top"' not in history
    assert "github.com" not in home.lower()
    static_history = (site / "release-notes.html").read_text()
    assert "Setup 安装向导" in static_history and "Unicode" in static_history
    assert "正式安装版" in static_history and "退出后继续显示备份、安装及完成状态" in static_history
    downloads = client.get("/downloads?lang=zh-CN").text
    assert 'id="release-list"' in downloads and "BobTV.exe" in downloads
    assert 'id="release-title"' in downloads
    assert 'id="first-launch-title"' in downloads and "v" + version.split("+")[0] in history
    assert "1.1.10+103" not in downloads and "ad-hoc" in downloads
    assert "管理员授权" in downloads and "只读磁盘映像" in downloads
    assert "下载并校验 Setup" in downloads and "取消授权可继续使用旧版" in downloads
    assert "v0.9.1-bob.11" not in downloads
    assert 'class="downloads-page"' in downloads and 'class="back-top"' in downloads
    script = client.get("/assets/downloads.js").text
    assert "item.version === candidates[0]?.version" in script
    assert "${release.version} · ${format}" in script
    assert "const families" in script and "data-cpu" in script
    assert "Windows ARM64" in script and "Android ARM64" in script
    assert "Apple Silicon" in script and "Windows x64" in script
    diagnostics = client.get("/diagnostics?lang=zh-CN").text
    assert 'class="diagnostics-page"' in diagnostics and 'class="back-top"' not in diagnostics
    assert 'id="upload-form"' in diagnostics and 'id="log-file"' in diagnostics
    assert "默认关闭" in diagnostics
    assert "尚未集成自动上传" not in diagnostics


def test_android_manual_download_has_apk_mime(tmp_path, monkeypatch):
    monkeypatch.setattr(module, 'DATA', tmp_path)
    folder=tmp_path/'releases';folder.mkdir()
    name='BobTV-1.1.0+93-android-arm64.apk'
    (folder/name).write_bytes(b'PK\x03\x04test')
    (tmp_path/'releases.json').write_text(json.dumps({'releases':[{'filename':name}]}))
    client=TestClient(module.app)
    result=client.get('/downloads/'+name)
    assert result.status_code==200
    assert result.headers['content-type']=='application/vnd.android.package-archive'


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


def test_public_site_languages_and_cookie():
    client = TestClient(module.app, base_url="https://bobtv.briconbric.com")
    assert client.get("/", headers={"Accept-Language": "de;q=1, ko-KR;q=.7, ja;q=.5"}).headers["content-language"] == "ko"
    assert client.get("/", headers={"Accept-Language": "zh-Hant-HK"}).headers["content-language"] == "zh-TW"
    for locale in ("en", "zh-CN", "zh-TW", "ja", "fr", "es", "ko"):
        for path in module.PAGES:
            response = client.get(path + "?lang=" + locale)
            assert response.status_code == 200
            assert response.headers["content-language"] == locale
            assert f'<html lang="{locale}">' in response.text
            assert f'value="{locale}" selected' in response.text
    assert client.get("/downloads", headers={"Accept-Language": "fr"}).headers["content-language"] == "ko"


def test_china_routes_public_resources_to_mirror(monkeypatch):
    monkeypatch.setattr(module, "request_profile", lambda *_: {"countryCode": "CN"})
    client = TestClient(module.app, base_url="https://bobtv.briconbric.com")
    for path in ("/?lang=fr", "/downloads", "/release-notes", "/privacy", "/assets/site.css",
                 "/downloads/BobTV-test.zip", "/releases.json"):
        response = client.get(path, follow_redirects=False)
        assert response.status_code == 307
        assert response.headers["location"] == "https://cndrp.com/bobtv" + path
        assert response.headers["cache-control"] == "private, no-store"
    assert client.head("/assets/site.css", follow_redirects=False).status_code == 307
    assert client.get("/api/v1/resource-node/probe").status_code == 200

    monkeypatch.setattr(module, "trusted_client", lambda _: "114.114.114.114")
    response = client.get("/downloads?lang=fr", headers={"x-bobtv-relay-node": "cndrp"})
    assert response.status_code == 200
    assert 'src="/bobtv/assets/downloads.js' in response.text
    assert 'href="/bobtv/privacy"' in response.text
    assert 'href="/bobtv/release-notes"' in response.text
    assert 'action="/bobtv/downloads"' in response.text
    assert 'Path=/bobtv/' in response.headers["set-cookie"]
