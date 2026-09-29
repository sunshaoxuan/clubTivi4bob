import hashlib
import base64
import importlib.util
import io
import json
import os
import subprocess
import zipfile
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location("mirror", Path(__file__).parents[1] / "mirror_releases.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def update_zip(platform):
    output = io.BytesIO()
    root = "BobTV/" if platform == "windows-x64" else "BobTV.app/"
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as package:
        if platform == "windows-x64":
            package.writestr(root + "BobTV.exe", b"x" * 1_000_000)
            package.writestr(root + "data/app.so", b"data")
        else:
            package.writestr(root + "Contents/MacOS/BobTV", b"m" * 1_000_000)
            package.writestr(root + "Contents/Info.plist", b"plist")
    return output.getvalue()


def sign_test_archive(tmp_path, monkeypatch, content):
    private = tmp_path / "private.pem"
    public = tmp_path / "public.pem"
    archive = tmp_path / "signed.zip"
    signature = tmp_path / "signature.der"
    archive.write_bytes(content)
    subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey",
                    "-noout", "-out", str(private)], check=True)
    subprocess.run(["openssl", "pkey", "-in", str(private), "-pubout",
                    "-out", str(public)], check=True)
    subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(private),
                    "-out", str(signature), str(archive)], check=True)
    monkeypatch.setattr(module, "UPDATE_PUBLIC_KEY", public)
    return base64.b64encode(signature.read_bytes()).decode("ascii")


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
    update = update_zip("windows-x64")
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
    assert json.loads((tmp_path / "updates/approved.json").read_text())[update_name] == package["sha256"]

    assets[-1]["digest"] = "sha256:" + "0" * 64
    with pytest.raises(ValueError, match="checksum mismatch"):
        module.mirror()
    assert json.loads(manifest_path.read_text()) == manifest


def test_mac_only_update_can_publish_without_windows_download(tmp_path, monkeypatch):
    monkeypatch.setattr(module, "DATA", tmp_path)
    archive = update_zip("macos-arm64")
    signature = sign_test_archive(tmp_path, monkeypatch, archive)
    name = "BobTV-0.9.1+62-macos-arm64.zip"
    metadata = json.dumps({"schema": 1, "version": "0.9.1+62", "packages": [{
        "platform": "macos-arm64", "filename": name,
        "sha256": hashlib.sha256(archive).hexdigest(), "bytes": len(archive),
        "signature": signature,
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
    assert json.loads((tmp_path / "updates/macos-arm64/latest.json").read_text())["signature"] == signature
    assert not (tmp_path / "releases.json").exists()


def test_mac_update_rejects_missing_or_wrong_publisher_signature(tmp_path, monkeypatch):
    archive = update_zip("macos-arm64")
    valid = sign_test_archive(tmp_path, monkeypatch, archive)
    path = tmp_path / "signed.zip"
    module._verify_mac_signature(path, valid)
    with pytest.raises(ValueError, match="signature"):
        module._verify_mac_signature(path, None)
    path.write_bytes(archive + b"tampered")
    with pytest.raises(ValueError, match="signature"):
        module._verify_mac_signature(path, valid)


def test_update_archive_rejects_path_escape(tmp_path):
    path = tmp_path / "unsafe.zip"
    with zipfile.ZipFile(path, "w") as package:
        package.writestr("BobTV/BobTV.exe", b"app")
        package.writestr("BobTV/data/app.so", b"data")
        package.writestr("BobTV/../outside.txt", b"outside")
    with pytest.raises(ValueError, match="Unsafe"):
        module._inspect_update_archive(path, "windows-x64")
