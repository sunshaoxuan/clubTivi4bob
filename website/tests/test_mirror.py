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
