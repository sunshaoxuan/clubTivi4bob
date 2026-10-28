import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile

import pytest

spec = importlib.util.spec_from_file_location('prepare_route_decoder', Path(__file__).parents[2] / 'tools/prepare_route_recovery_decoder.py')
preparation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preparation)


def linux(monkeypatch):
    monkeypatch.setattr(preparation.platform, 'system', lambda: 'Linux')
    monkeypatch.setattr(preparation.platform, 'machine', lambda: 'x86_64')


def test_existing_unknown_tool_cannot_be_overwritten(tmp_path, monkeypatch):
    linux(monkeypatch)
    directory = tmp_path / 'route-recovery'
    directory.mkdir()
    binary = directory / 'ffmpeg'
    binary.write_bytes(b'user tool')
    monkeypatch.setattr(preparation, 'download', lambda *_: pytest.fail('must not download'))
    with pytest.raises(ValueError, match='preserved'):
        preparation.prepare(directory, replace_incompatible=True)
    assert binary.read_bytes() == b'user tool'


def package(monkeypatch, binary=b'new decoder'):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w:xz') as archive:
        item = tarfile.TarInfo('build/bin/ffmpeg')
        item.size = len(binary)
        archive.addfile(item, io.BytesIO(binary))
    body = stream.getvalue()
    metadata = {'assets': [{'name': preparation.LINUX_ASSET,
        'browser_download_url': 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/' + preparation.LINUX_ASSET,
        'digest': 'sha256:' + hashlib.sha256(body).hexdigest()}]}
    monkeypatch.setattr(preparation, 'download', lambda url, _: json.dumps(metadata).encode() if 'api.github' in url else body)
    return body


def test_verified_decoder_requires_ts_smoke_before_switch(tmp_path, monkeypatch):
    linux(monkeypatch)
    directory = tmp_path / 'route-recovery'
    directory.mkdir()
    old = directory / 'ffmpeg'
    old.write_bytes(b'known old tool')
    monkeypatch.setattr(preparation, 'INCOMPATIBLE_LINUX_SHA', hashlib.sha256(old.read_bytes()).hexdigest())
    package(monkeypatch)
    def fails(_):
        raise ValueError('TS decode failed')
    monkeypatch.setattr(preparation, 'smoke_ts', fails)
    with pytest.raises(ValueError, match='TS decode failed'):
        preparation.prepare(directory, True)
    assert old.read_bytes() == b'known old tool'
    monkeypatch.setattr(preparation, 'smoke_ts', lambda _: None)
    monkeypatch.setattr(preparation.subprocess, 'run', lambda *a, **k: subprocess.CompletedProcess(a, 0, stdout=b'ffmpeg test\n'))
    result = preparation.prepare(directory, True)
    assert result['silentTsSmokePassed']
    assert old.read_bytes() == b'new decoder'
    assert (directory / 'ffmpeg-imageio-7.0.2-ts-incompatible').read_bytes() == b'known old tool'


def test_archive_hash_mismatch_is_rejected(tmp_path, monkeypatch):
    linux(monkeypatch)
    package(monkeypatch)
    download = preparation.download
    monkeypatch.setattr(preparation, 'download', lambda url, limit: download(url, limit) if 'api.github' in url else b'tampered')
    with pytest.raises(ValueError, match='checksum mismatch'):
        preparation.prepare(tmp_path / 'route-recovery')
