import asyncio
import json
from pathlib import Path
import sqlite3
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).parents[1]))
import catalog_inventory as inventory
import httpx
from fastapi import FastAPI
from fastapi.testclient import TestClient
import network_routes

URL = 'https://media.example.org/fixture.m3u8'
EVENT = {'schemaVersion': 1, 'fingerprint': 'a' * 64,
    'events': [{'id': 'b' * 32, 'url': URL, 'kind': 'retire'}]}


def application(tmp_path, monkeypatch):
    monkeypatch.setattr(inventory, 'DATA', tmp_path)
    monkeypatch.setattr(inventory, '_publish_changes', lambda: None)
    with inventory.database(tmp_path):
        pass
    app = FastAPI()
    app.include_router(inventory.router)
    app.include_router(network_routes.router)
    return app


def test_slow_event_write_does_not_block_live_retirement_reads(tmp_path, monkeypatch):
    app = application(tmp_path, monkeypatch)
    started, release = threading.Event(), threading.Event()
    def slow_write(*args, **kwargs):
        started.set()
        assert release.wait(3)
        return {'schemaVersion': 1, 'receipts': []}
    monkeypatch.setattr(inventory, 'ingest_events', slow_write)
    async def check():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
            writing = asyncio.create_task(client.post('/api/v1/channel-catalog/events', json=EVENT))
            try:
                assert await asyncio.to_thread(started.wait, 1)
                response = await asyncio.wait_for(client.post('/api/v1/channel-catalog/route-state',
                    json={'schemaVersion': 1, 'urls': [URL]}), timeout=1)
                assert response.status_code == 200
                assert response.json()['urls'] == []
            finally:
                release.set()
            assert (await writing).status_code == 202
    asyncio.run(check())


def test_busy_writer_queues_and_preserves_idempotent_retirement(tmp_path, monkeypatch):
    app = application(tmp_path, monkeypatch)
    client = TestClient(app)
    lock = sqlite3.connect(tmp_path / 'channel_inventory.sqlite3')
    lock.execute('BEGIN IMMEDIATE')
    try:
        started = time.monotonic()
        response = client.post('/api/v1/channel-catalog/events', json=EVENT)
        assert response.status_code == 202
        assert response.headers['retry-after'] == '15'
        assert response.json()['queued'] is True
        assert response.json()['receipts'][0]['status'] == 'retry'
        assert time.monotonic() - started < 2.5
        # A WAL reader remains usable while another process owns the write lock.
        assert client.post('/api/v1/channel-catalog/route-state',
            json={'schemaVersion': 1, 'urls': [URL]}).status_code == 200
        profile = client.get('/api/v1/channel-catalog/network-profile')
        assert profile.status_code == 200  # Network quotas have an independent store.
    finally:
        lock.rollback()
        lock.close()
    from catalog_event_queue import drain
    assert drain(tmp_path)['processed'] == 1
    first = client.post('/api/v1/channel-catalog/events', json=EVENT)
    assert first.status_code == 202
    assert client.post('/api/v1/channel-catalog/events', json=EVENT).json() == first.json()
    # Lost acknowledgments can be read even while another writer owns the WAL.
    lock = sqlite3.connect(tmp_path / 'channel_inventory.sqlite3')
    lock.execute('BEGIN IMMEDIATE')
    try:
        assert client.post('/api/v1/channel-catalog/events', json=EVENT).json() == first.json()
    finally:
        lock.rollback()
        lock.close()
    assert client.post('/api/v1/channel-catalog/route-state',
        json={'schemaVersion': 1, 'urls': [URL]}).json()['urls'] == [URL]
    with inventory.database(tmp_path) as conn:
        assert conn.execute('SELECT count(*) FROM sync_receipts').fetchone()[0] == 1
        assert conn.execute('SELECT blocked FROM routes').fetchone()[0] == 1
