import hashlib
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).parents[1]))
import resource_nodes as nodes
import resource_relay as relay


def test_media_and_arbitrary_destinations_rejected():
    assert not relay.allowed('/api/v1/egress/resource', 'kind=media&url=https://a/live.m3u8', 'GET')
    assert not relay.allowed('/api/v1/egress/resource', 'kind=image&kind=media', 'GET')
    assert not relay.allowed('/admin', '', 'GET')
    assert not relay.allowed('/updates/../secret', '', 'GET')
    assert not relay.allowed('/downloads/BobTV-test.zip', '', 'POST')
    assert relay.allowed('/api/v1/channel-catalog/events', '', 'POST')
    assert relay.allowed('/api/v1/egress/resource', 'kind=epg&url=https://a/epg.xml', 'GET')


def test_probe_has_identical_bounded_body_and_node_identity():
    app = FastAPI()
    app.include_router(nodes.router)
    client = TestClient(app)
    result = client.get('/api/v1/resource-node/probe')
    assert len(result.content) == 65536
    assert result.content == nodes.PROBE_BODY
    assert result.headers['x-bobtv-node'] == 'origin'
    assert result.headers['cache-control'] == 'no-store'
    assert client.head('/api/v1/resource-node/probe').content == b''


def test_verified_relay_preserves_client_and_forged_headers_fail(tmp_path, monkeypatch):
    secret = 'a' * 64
    config = tmp_path / 'relay.json'
    config.write_text(json.dumps({'nodes': {'cndrp': {'enabled': True,
        'addresses': ['121.43.197.117'], 'secret': secret}}}))
    monkeypatch.setenv('BOBTV_RESOURCE_RELAYS', str(config))
    def request(peer='121.43.197.117', stamp='100', ip='8.8.4.4', auth=None):
        return Request({'type': 'http', 'method': 'POST', 'scheme': 'https',
            'path': '/api/v1/channel-catalog/events', 'query_string': b'',
            'server': ('bobtv.briconbric.com', 443), 'client': (peer, 123),
            'headers': [(k.encode(), v.encode()) for k, v in {
                'x-bobtv-relay-node': 'cndrp', 'x-bobtv-relay-client': ip,
                'x-bobtv-relay-time': stamp, 'x-bobtv-relay-auth': auth or nodes.signature(secret,
                    'POST', '/api/v1/channel-catalog/events', ip, stamp)}.items()]})
    assert nodes.trusted_client(request(), now=100) == '8.8.4.4'
    for req in [request(peer='8.8.8.8'), request(stamp='1'), request(auth='bad')]:
        with pytest.raises(Exception) as error: nodes.trusted_client(req, now=100)
        assert error.value.status_code == 403


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv('BOBTV_RELAY_SECRET', 'a' * 64)
    seen = []
    def handle(request):
        seen.append(request)
        if request.url.path == nodes.router.prefix + '/probe':
            return httpx.Response(200, content=nodes.PROBE_BODY)
        if request.url.path.endswith('/redirect'):
            return httpx.Response(302, headers={'location': 'https://github.com/evil'})
        if request.url.path.startswith('/updates/'):
            return httpx.Response(206, stream=httpx.ByteStream(b'package'), headers={'Content-Range': 'bytes 0-6/100',
                'Content-Type': 'application/zip', 'ETag': 'test'})
        return httpx.Response(202, stream=httpx.ByteStream(request.content),
            headers={'Content-Type': 'application/json', 'Cache-Control': 'no-store'})
    with TestClient(relay.app, client=('8.8.4.4', 123)) as test:
        original = relay.app.state.client
        relay.app.state.client = httpx.AsyncClient(transport=httpx.MockTransport(handle))
        yield test, seen
        test.portal.call(relay.app.state.client.aclose)
        relay.app.state.client = original


def test_upload_exact_body_and_idempotency_are_forwarded_once(client):
    test, seen = client
    body = b'{"id":"abc","kind":"merge"}'
    response = test.post('/bobtv/api/v1/channel-catalog/events', content=body,
        headers={'Content-Type': 'application/json', 'Idempotency-Key': 'event-1',
            'X-Forwarded-For': '1.2.3.4', 'X-BobTV-Relay-Client': '1.2.3.4'})
    assert response.status_code == 202 and response.content == body
    assert len(seen) == 1
    outgoing = seen[0]
    assert outgoing.url.host == 'bobtv.briconbric.com'
    assert outgoing.headers['idempotency-key'] == 'event-1'
    assert outgoing.headers['x-bobtv-relay-client'] == '8.8.4.4'
    assert outgoing.headers['x-bobtv-relay-auth'] == nodes.signature('a' * 64,
        'POST', '/api/v1/channel-catalog/events', '8.8.4.4', outgoing.headers['x-bobtv-relay-time'])


def test_range_hash_and_redirect_protection(client):
    test, seen = client
    result = test.get('/bobtv/updates/files/BobTV-test.zip', headers={'Range': 'bytes=0-6'})
    assert result.status_code == 206 and result.content == b'package'
    assert result.headers['content-range'] == 'bytes 0-6/100'
    assert seen[0].headers['range'] == 'bytes=0-6'
    assert test.get('/bobtv/api/v1/redirect').status_code == 502
    assert test.get('/bobtv/api/v1/egress/resource?kind=media&url=https://a/live').status_code == 403


def test_large_upload_rejected_without_origin_request(client):
    test, seen = client
    assert test.post('/bobtv/api/v1/logs', content=b'x' * (relay.MAX_UPLOAD + 1)).status_code == 413
    assert seen == []


def test_browser_upload_preflight_is_restricted_to_bobtv(client):
    test, seen = client
    headers = {'Origin': relay.ORIGIN, 'Access-Control-Request-Method':'POST',
        'Access-Control-Request-Headers':'content-type'}
    result = test.options('/bobtv/api/v1/logs', headers=headers)
    assert result.status_code == 200 and result.headers['access-control-allow-origin'] == relay.ORIGIN
    headers['Origin'] = 'https://unrelated.example.org'
    assert test.options('/bobtv/api/v1/logs', headers=headers).status_code == 400
    assert seen == []
