import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location("mirror", Path(__file__).parents[1] / "mirror_releases.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def test_mirror_publishes_only_verified_zip(tmp_path, monkeypatch):
    monkeypatch.setattr(module, "DATA", tmp_path)
    payload = b"PK\x03\x04release"
    asset = {"name": "BobTV-v1-windows-x64.zip", "size": len(payload), "browser_download_url": "asset", "digest": "sha256:" + hashlib.sha256(payload).hexdigest()}
    releases = [{"tag_name": "v1", "published_at": "2026-09-27T00:00:00Z", "assets": [asset]}]
    monkeypatch.setattr(module, "request", lambda url: io.BytesIO(json.dumps(releases).encode() if url == module.API else payload))
    module.mirror()
    assert (tmp_path / "releases" / asset["name"]).read_bytes() == payload
    assert json.loads((tmp_path / "releases.json").read_text())["releases"][0]["sha256"] == hashlib.sha256(payload).hexdigest()

    if os.name != "nt":
        (tmp_path / "releases" / asset["name"]).write_bytes(b"PK\x03\x04corrupt")
        module.mirror()
        assert (tmp_path / "releases" / asset["name"]).read_bytes() == payload

    asset["digest"] = "sha256:" + "0" * 64
    with pytest.raises(ValueError, match="checksum mismatch"):
        module.mirror()
    assert (tmp_path / "releases" / asset["name"]).read_bytes() == payload


def test_mirror_publishes_platform_update_only_after_checksum_verification(tmp_path, monkeypatch):
    monkeypatch.setattr(module, "DATA", tmp_path)
    legacy = b"PK\x03\x04release"
    update = b"PK\x03\x04" + b"x" * 1_000_000
    update_name = "BobTV-0.9.1+61-windows-x64.zip"
    package = {"platform": "windows-x64", "filename": update_name,
               "sha256": hashlib.sha256(update).hexdigest(), "bytes": len(update)}
    metadata = json.dumps({"schema": 1, "version": "0.9.1+61",
                           "packages": [package]}).encode()
    assets = [
        {"name": "BobTV-v1-windows-x64.zip", "size": len(legacy),
         "browser_download_url": "legacy"},
        {"name": module.UPDATE_METADATA, "size": len(metadata),
         "browser_download_url": "metadata",
         "digest": "sha256:" + hashlib.sha256(metadata).hexdigest()},
        {"name": update_name, "size": len(update),
         "browser_download_url": "update",
         "digest": "sha256:" + hashlib.sha256(update).hexdigest()},
    ]
    releases = [{"tag_name": "v1", "published_at": "2026-09-30T00:00:00Z",
                 "assets": assets}]
    responses = {"legacy": legacy, "metadata": metadata, "update": update}
    monkeypatch.setattr(module, "request", lambda url: io.BytesIO(
        json.dumps(releases).encode() if url == module.API else responses[url]))
    module.mirror()
    manifest_path = tmp_path / "updates/windows-x64/latest.json"
    manifest = json.loads(manifest_path.read_text())
    assert manifest["version"] == "0.9.1+61"
    assert manifest["sha256"] == package["sha256"]
    assert (tmp_path / "updates/files" / update_name).read_bytes() == update

    assets[-1]["digest"] = "sha256:" + "0" * 64
    with pytest.raises(ValueError, match="checksum mismatch"):
        module.mirror()
    assert json.loads(manifest_path.read_text()) == manifest


def test_mac_only_update_can_publish_without_windows_download(tmp_path, monkeypatch):
    monkeypatch.setattr(module, "DATA", tmp_path)
    archive = b"PK\x03\x04" + b"m" * 1_000_000
    name = "BobTV-0.9.1+62-macos-arm64.zip"
    metadata = json.dumps({"schema": 1, "version": "0.9.1+62", "packages": [{
        "platform": "macos-arm64", "filename": name,
        "sha256": hashlib.sha256(archive).hexdigest(), "bytes": len(archive),
    }]}).encode()
    releases = [{"tag_name": "mac-release", "published_at": "2026-09-30T00:00:00Z",
                 "assets": [
                     {"name": module.UPDATE_METADATA, "size": len(metadata),
                      "browser_download_url": "metadata"},
                     {"name": name, "size": len(archive),
                      "browser_download_url": "archive"},
                 ]}]
    monkeypatch.setattr(module, "request", lambda url: io.BytesIO(
        json.dumps(releases).encode() if url == module.API else
        {"metadata": metadata, "archive": archive}[url]))
    module.mirror()
    assert json.loads((tmp_path / "updates/macos-arm64/latest.json").read_text())["version"] == "0.9.1+62"
    assert not (tmp_path / "releases.json").exists()
