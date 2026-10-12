"""Publisher finalization must authenticate managed Windows Setup payloads."""
import hashlib
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

script = Path(__file__).resolve().parents[2] / 'tools/finalize_desktop_update_metadata.py'
spec = importlib.util.spec_from_file_location('bobtv_finalize_metadata', script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fixture(tmp_path, monkeypatch):
    version = '1.1.2+95'
    archive = tmp_path / f'BobTV-{version}-windows-x64.zip'
    archive.write_bytes(b'ZIP fixture: archive validation has its own tests')
    installer = tmp_path / f'BobTV-{version}-windows-x64-Setup.exe'
    payload = bytearray(1_000_000)
    payload[:2] = b'MZ'
    payload[60:64] = (64).to_bytes(4, 'little')
    payload[64:68] = b'PE\x00\x00'
    installer.write_bytes(payload)
    monkeypatch.setattr(module, '_inspect_update_archive', lambda *args: None)
    monkeypatch.delenv('BOBTV_UPDATE_SIGNING_KEY', raising=False)
    return version, installer


def test_finalization_requires_key_for_managed_windows(tmp_path, monkeypatch):
    version, _ = fixture(tmp_path, monkeypatch)
    monkeypatch.setattr(sys, 'argv', ['finalize', str(tmp_path), version,
                                    '--platforms', 'windows-x64'])
    with pytest.raises(ValueError, match='publisher signing key'):
        module.main()
    assert not (tmp_path / 'BobTV-update-metadata.json').exists()


def test_finalization_signs_setup_and_verifies_pinned_key(tmp_path, monkeypatch):
    version, installer = fixture(tmp_path, monkeypatch)
    private = tmp_path / 'fixture-private.pem'
    public = tmp_path / 'fixture-public.pem'
    subprocess.run(['openssl', 'ecparam', '-name', 'prime256v1', '-genkey',
                    '-noout', '-out', str(private)], check=True, capture_output=True)
    subprocess.run(['openssl', 'pkey', '-in', str(private), '-pubout',
                    '-out', str(public)], check=True, capture_output=True)
    monkeypatch.setattr(sys.modules['mirror_releases'], 'UPDATE_PUBLIC_KEY', public)
    monkeypatch.setattr(sys, 'argv', ['finalize', str(tmp_path), version,
                                    '--platforms', 'windows-x64',
                                    '--signing-key', str(private)])
    module.main()
    metadata = json.loads((tmp_path / 'BobTV-update-metadata.json').read_text())
    setup = metadata['packages'][0]['installer']
    assert setup['filename'] == installer.name
    assert setup['sha256'] == hashlib.sha256(installer.read_bytes()).hexdigest()
    module._verify_mac_signature(installer, setup['signature'])
    assert installer.name in (tmp_path / 'SHA256SUMS.txt').read_text()
    # Reject invalid executable structure before replacing good metadata.
    before = (tmp_path / 'BobTV-update-metadata.json').read_bytes()
    installer.write_bytes(b'not a Windows executable')
    with pytest.raises(ValueError, match='Invalid Windows installer'):
        module.main()
    assert (tmp_path / 'BobTV-update-metadata.json').read_bytes() == before
