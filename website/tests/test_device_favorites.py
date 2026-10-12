import hashlib
import json
import sqlite3
import sys
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).parents[1]))
import device_favorites as favorites
sys.path.pop(0)

PATH = '/api/v1/device-favorites'


def headers(token='a', fingerprint='1'):
    return {'Authorization': 'Bearer btvf1_' + token * 64,
            'X-BobTV-Device-Fingerprint': fingerprint * 64}


def snapshot(name='只属于设备 A 的收藏', routes=None):
    return {'lists': [{'id': 'default', 'name': name, 'icon': 'star', 'sortOrder': 0,
                       'routes': routes or ['f' * 64]}], 'legacyRoutes': []}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(favorites, 'DATA', tmp_path)
    app = FastAPI()
    app.include_router(favorites.router)
    return TestClient(app)


def save(client, value, *, base=0, device_headers=None):
    return client.put(PATH, headers=device_headers or headers(),
                      json={'schemaVersion': 1, 'baseRevision': base, 'snapshot': value})


def test_favorites_upload_restore_and_original_device_isolation(client, tmp_path):
    own = snapshot()
    assert save(client, own).json() == {'revision': 1, 'duplicate': False}
    response = client.get(PATH, headers=headers())
    assert response.json()['snapshot'] == own
    assert response.headers['cache-control'] == 'private, no-store'
    assert response.headers['vary'] == 'Authorization, X-BobTV-Device-Fingerprint'
    assert client.get(PATH).status_code == 401
    # A public fingerprint alone, a fresh device key, or a reused key with a
    # different fingerprint never returns another machine's favorite data.
    assert client.get(PATH, headers={'X-BobTV-Device-Fingerprint': '1' * 64}).status_code == 401
    assert client.get(PATH, headers=headers('b', '1')).status_code == 404
    assert client.get(PATH, headers=headers('a', '2')).status_code == 403
    assert save(client, snapshot('设备 B 自己的收藏'), device_headers=headers('b', '2')).status_code == 200
    assert client.get(PATH, headers=headers()).json()['snapshot'] == own
    assert client.get(PATH, headers=headers('b', '2')).json()['snapshot']['lists'][0]['name'] == '设备 B 自己的收藏'
    assert client.get(PATH + '?fingerprint=' + '1' * 64, headers=headers()).status_code == 401
    with sqlite3.connect(tmp_path / 'device_favorites.sqlite3') as conn:
        raw = str(conn.execute('SELECT * FROM favorites').fetchall())
    assert 'btvf1_' not in raw
    assert hashlib.sha256(('1' * 64).encode()).hexdigest() in raw
    assert not (tmp_path / 'channel_inventory.sqlite3').exists()


def test_conditional_reads_and_idempotent_retry_do_not_undo_removal(client):
    assert save(client, snapshot()).json()['revision'] == 1
    assert save(client, snapshot()).json() == {'revision': 1, 'duplicate': True}
    result = client.get(PATH, headers={**headers(), 'If-None-Match': '"favorites-v1-1"'})
    assert result.status_code == 304 and not result.content
    cleared = {'lists': [], 'legacyRoutes': []}
    assert save(client, cleared, base=1).json()['revision'] == 2
    assert save(client, snapshot(), base=1).status_code == 409
    assert client.get(PATH, headers=headers()).json()['snapshot'] == cleared


def test_only_selection_hashes_are_accepted_not_credentials_or_urls(client):
    for malformed in [
        {**snapshot(), 'url': 'https://private.example/?token=secret'},
        {**snapshot(), 'password': 'private'},
        snapshot(routes=['http://192.168.1.1/live.m3u8']),
        snapshot(routes=['f' * 64, 'f' * 64]),
        snapshot(routes=[{'url': 'https://stream.example/live'}]),
        {'lists': [*snapshot()['lists'], *snapshot()['lists']], 'legacyRoutes': []},
        {'lists': [], 'legacyRoutes': ['x' * 64]},
    ]:
        response = save(client, malformed)
        assert response.status_code == 422
        assert response.headers['cache-control'] == 'private, no-store'
    assert client.get(PATH, headers=headers()).status_code == 404
    assert client.put(PATH, headers=headers(), content=b'x' * (favorites.MAX_BODY + 1)).status_code == 415
    assert client.put(PATH, headers={**headers(), 'Content-Type': 'application/json'},
                      content=b'x' * (favorites.MAX_BODY + 1)).status_code == 413


def test_private_errors_remain_uncacheable_and_reads_are_bounded(client):
    assert save(client, snapshot()).status_code == 200
    assert client.get(PATH, headers=headers('a', '2')).headers['cache-control'] == 'private, no-store'
    for _ in range(498):
        assert client.get(PATH, headers=headers()).status_code == 200
    assert client.get(PATH, headers=headers()).status_code == 429


def test_backup_contains_private_database_but_no_public_favorite_snapshot(client, tmp_path):
    assert save(client, snapshot()).status_code == 200
    from backup_server_data import backup
    result = backup(tmp_path)
    assert result['databases'] == ['device_favorites.sqlite3']
    assert result['catalog'] is None
    assert (Path(result['backup']) / 'device_favorites.sqlite3').stat().st_mode & 0o777 == 0o600
