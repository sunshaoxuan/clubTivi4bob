import importlib.util
import json
import sys
from pathlib import Path

from fastapi.testclient import TestClient

site = Path(__file__).parents[1]
sys.path.insert(0, str(site))
import update_delivery
spec = importlib.util.spec_from_file_location("bobtv_update_app", site / "app.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
sys.path.remove(str(site))


def test_update_delivery_requires_published_manifest(tmp_path, monkeypatch):
    monkeypatch.setattr(update_delivery, "DATA", tmp_path)
    client = TestClient(module.app)
    assert client.get("/updates/windows-x64/latest.json").status_code == 404
    assert client.get("/updates/files/BobTV-1.0.0+1-windows-x64.zip").status_code == 404
    assert client.get("/updates/unknown/latest.json").status_code == 404

    filename = "BobTV-1.0.0+1-windows-x64.zip"
    target = tmp_path / "updates/files" / filename
    target.parent.mkdir(parents=True)
    target.write_bytes(b"PK\x03\x04test")
    manifest = {"schema": 1, "version": "1.0.0+1",
                "archive": f"https://bobtv.briconbric.com/updates/files/{filename}",
                "sha256": "a" * 64, "bytes": target.stat().st_size}
    manifest_file = tmp_path / "updates/windows-x64/latest.json"
    manifest_file.parent.mkdir(parents=True)
    manifest_file.write_text(json.dumps(manifest))
    assert client.get("/updates/windows-x64/latest.json").json() == manifest
    assert client.get(f"/updates/files/{filename}").content == target.read_bytes()
    assert client.get("/updates/files/other.zip").status_code == 404
