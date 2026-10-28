import asyncio
import hashlib
import json
import os
from datetime import datetime, timezone

import httpx
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

import diagnostic_store as storage
import diagnostics_api
from diagnostic_relay_worker import forward
import resource_relay as relay


def batch(now=1792764000, **entry):
    return json.dumps({'schemaVersion': 2, 'consentVersion': 2,
        'installationId': 'a' * 32, 'entries': [{
            'time': datetime.fromtimestamp(now, timezone.utc).isoformat().replace('+00:00', 'Z'),
            'event': 'network_request', 'platform': 'android', 'appVersion': '1.1.7+100',
            'phase': 'headers', 'node': 'origin', 'endpoint': 'catalog_manifest',
            'errorCode': 'timeout', **entry}]}).encode()


def test_strict_projection_timestamp_schema_and_sensitive_fields():
    now = 1792764000
    assert storage.validate_batch(batch(), now)[0]['schemaVersion'] == 2
    for key in ['url', 'error', 'stack', 'channel', 'password', 'token', 'path', 'favorites']:
        with pytest.raises(ValueError):
            storage.validate_batch(batch(**{key: 'private'}), now)
    for value in [batch(now - storage.RETENTION), batch(now + 301),
                  batch(phase='secret'), batch(httpStatus=True), batch(elapsedMs=float('nan')),
                  batch(source='https://user:password@private.test/path')]:
        with pytest.raises(ValueError):
            storage.validate_batch(value, now)
    with pytest.raises(ValueError):
        storage.validate_batch(batch().replace(b'"consentVersion": 2', b'"consentVersion": 1'), now)


def test_private_durable_idempotent_store_limits_and_event_age_expiry(tmp_path):
    now = 1792764000
    body = batch(now - 29 * 86400)
    store = storage.DiagnosticStore(tmp_path, maximum=len(body))
    first = store.put(body, now=now)
    assert first['state'] == 'origin_accepted'
    assert storage.DiagnosticStore(tmp_path).receipt(first['id'], now)['state'] == 'origin_accepted'
    assert store.put(body, now=now)['duplicate'] is True
    with pytest.raises(storage.StoreLimit):
        store.put(batch(now, event='heartbeat'), now=now)
    assert os.stat(tmp_path / 'batches.sqlite3').st_mode & 0o777 == 0o600
    store.prune(now + 86401)
    assert store.receipt(first['id'], now + 86401) is None
    assert store.put(batch(now + 86401), now=now + 86401)['duplicate'] is False


def test_origin_api_has_no_payload_read_and_no_shared_cache(tmp_path, monkeypatch):
    monkeypatch.setenv('BOBTV_DATA_DIR', str(tmp_path))
    monkeypatch.delenv('BOBTV_DIAGNOSTICS_DIR', raising=False)
    import time
    body = batch(int(time.time()))
    app = FastAPI()
    app.include_router(diagnostics_api.router)
    client = TestClient(app)
    response = client.post('/api/v1/diagnostics/batches', content=body, headers={'Content-Type': 'application/json'})
    assert response.status_code == 201
    assert 'no-store' in response.headers['cache-control']
    receipt = response.json()
    assert receipt['id'] == hashlib.sha256(body).hexdigest()
    assert client.post('/api/v1/diagnostics/batches', content=body, headers={'Content-Type': 'application/json'}).status_code == 200
    assert set(client.get('/api/v1/diagnostics/batches/' + receipt['id']).json()) == {'id', 'state'}
    assert client.get('/api/v1/diagnostics/batches/' + receipt['id'] + '/body').status_code == 404
    assert client.post('/api/v1/diagnostics/batches', content=b'x' * (storage.MAX_BODY + 1), headers={'Content-Type': 'application/json'}).status_code == 413
    assert client.post('/api/v1/diagnostics/batches', content=body, headers={'Content-Type': 'application/json', 'Content-Encoding': 'gzip'}).status_code == 415


def test_relay_storage_fault_is_retryable_and_not_shared_cached(monkeypatch):
    import sqlite3
    class Busy:
        def put(self, *args, **kwargs):
            raise sqlite3.OperationalError('locked fixture')
        def receipt(self, *args, **kwargs):
            raise OSError('fixture storage unavailable')
    monkeypatch.setattr(relay, 'diagnostic_store', lambda: Busy())
    monkeypatch.setenv('BOBTV_RELAY_SECRET', 'b' * 64)
    with TestClient(relay.app) as client:
        for response in [client.post('/bobtv/api/v1/diagnostics/batches', content=batch(), headers={'Content-Type': 'application/json'}),
                         client.get('/bobtv/api/v1/diagnostics/batches/' + 'a' * 64)]:
            assert response.status_code == 503
            assert response.headers['retry-after'] == '30'
            assert 'no-store' in response.headers['cache-control']


def test_relay_accepts_when_origin_offline_then_worker_recovers_after_restart(tmp_path, monkeypatch):
    import time
    now = int(time.time())
    queue = storage.DiagnosticStore(tmp_path / 'relay', state='relay_stored')
    origin = storage.DiagnosticStore(tmp_path / 'origin')
    monkeypatch.setattr(relay, 'diagnostic_store', lambda: queue)
    monkeypatch.setenv('BOBTV_RELAY_SECRET', 'b' * 64)
    body = batch(now)
    with TestClient(relay.app) as client:
        response = client.post('/bobtv/api/v1/diagnostics/batches', content=body, headers={'Content-Type': 'application/json'})
        assert response.status_code == 202 and response.json()['state'] == 'relay_stored'
        digest = response.json()['id']
        assert 'no-store' in response.headers['cache-control']
    # A new object models a service restart, retaining the exact immutable body.
    queue = storage.DiagnosticStore(tmp_path / 'relay', state='relay_stored')
    async def check():
        def fail(request):
            raise httpx.ReadTimeout('fixture offline')
        async with httpx.AsyncClient(transport=httpx.MockTransport(fail)) as upstream:
            result = await forward(upstream, queue, 'b' * 64, '121.43.197.117', 'https://origin.test', now=now)
            assert result == {'forwarded': 0, 'deferred': 1}
        assert queue.receipt(digest, now)['state'] == 'relay_stored'
        assert queue.due(now=now) == []
        def success(request):
            receipt = origin.put(request.content, now=now + 61)
            return httpx.Response(201, json=receipt, headers={'Cache-Control': 'private, no-store'})
        async with httpx.AsyncClient(transport=httpx.MockTransport(success)) as upstream:
            assert (await forward(upstream, queue, 'b' * 64, '121.43.197.117', 'https://origin.test', now=now + 61))['forwarded'] == 1
        assert queue.receipt(digest, now + 61)['state'] == 'origin_accepted'
        with queue.database() as conn:
            assert conn.execute('SELECT body FROM batches WHERE id=?', (digest,)).fetchone()[0] is None
        assert origin.receipt(digest, now + 61)['state'] == 'origin_accepted'
    asyncio.run(check())


@pytest.mark.parametrize('response', [
    httpx.Response(200, json={'id': '0' * 64, 'state': 'origin_accepted'}, headers={'Cache-Control': 'no-store'}),
    httpx.Response(200, json={'id': hashlib.sha256(batch()).hexdigest(), 'state': 'origin_accepted'}),
    httpx.Response(503, headers={'Retry-After': '3600'}),
])
def test_bad_or_lost_ack_never_discards_relay_payload(tmp_path, response):
    now = 1792764000
    queue = storage.DiagnosticStore(tmp_path, state='relay_stored')
    digest = queue.put(batch(), now=now)['id']
    async def check():
        async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: response)) as upstream:
            await forward(upstream, queue, 'b' * 64, '121.43.197.117', 'https://origin.test', now=now)
    asyncio.run(check())
    assert queue.receipt(digest, now)['state'] == 'relay_stored'
    with queue.database() as conn:
        assert conn.execute('SELECT length(body) FROM batches').fetchone()[0] > 0
