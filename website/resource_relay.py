"""Fixed-origin BobTV resource relay. No arbitrary destinations or media relay.

Shared GET files are cached by Nginx. All mutations and mutable API reads stream
to the canonical database without caching or autonomous mutation retries.
"""
import asyncio
from contextlib import asynccontextmanager
import ipaddress
import os
import time
from urllib.parse import parse_qs

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import Response, StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
from starlette.background import BackgroundTask

from resource_nodes import PROBE_BODY, PROBE_VERSION, signature

ORIGIN = 'https://bobtv.briconbric.com'
PREFIX = '/bobtv'
MAX_UPLOAD = 1024 * 1024
_health_time = 0.0
_healthy = False
_health_lock = asyncio.Lock()


def origin_url(path):
    address = os.environ.get('BOBTV_RELAY_ORIGIN_IP')
    if address:
        address = ipaddress.ip_address(address)
        if not address.is_global: raise ValueError('Origin requires public address')
        host = f'[{address}]' if address.version == 6 else str(address)
        return 'https://' + host + path
    return ORIGIN + path


def origin_extensions():
    return {'sni_hostname': 'bobtv.briconbric.com'}


def allowed(path, query, method):
    if method not in {'GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'PATCH'}:
        return False
    if '\\' in path or any(p in {'.', '..'} for p in path.split('/')):
        return False
    if path == '/api/v1/egress/resource':
        # Image, EPG and playlist documents are metadata resources. Video HLS,
        # DASH, TS segments and recordings are never admitted to this node.
        return method in {'GET', 'HEAD'} and parse_qs(query).get('kind') in (
            ['image'], ['epg'], ['playlist'])
    if path.startswith('/api/v1/'): return True
    if method not in {'GET', 'HEAD'}: return False
    return path.startswith(('/updates/', '/downloads/BobTV-', '/assets/')) or path == '/releases.json'


@asynccontextmanager
async def lifespan(app):
    secret = os.environ.get('BOBTV_RELAY_SECRET', '')
    if len(secret) < 64: raise RuntimeError('Resource relay secret unavailable')
    app.state.secret = secret
    app.state.client = httpx.AsyncClient(follow_redirects=False, trust_env=False,
        timeout=httpx.Timeout(30, connect=5),
        limits=httpx.Limits(max_connections=32, max_keepalive_connections=8))
    yield
    await app.state.client.aclose()


app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=[ORIGIN],
    allow_methods=['GET','HEAD','POST'], allow_headers=['Content-Type','Authorization','Range','If-Range','Idempotency-Key'],
    expose_headers=['X-BobTV-Probe','X-BobTV-Node','X-BobTV-Cache','Content-Length'])


async def origin_ready(client):
    global _health_time, _healthy
    if time.monotonic() - _health_time < 20: return _healthy
    async with _health_lock:
        if time.monotonic() - _health_time < 20: return _healthy
        try:
            response = await client.get(origin_url('/api/v1/resource-node/probe'),
                headers={'Accept-Encoding': 'identity', 'Host': 'bobtv.briconbric.com'},
                extensions=origin_extensions(), timeout=2)
            _healthy = response.status_code == 200 and response.content == PROBE_BODY
        except httpx.HTTPError:
            _healthy = False
        _health_time = time.monotonic()
        return _healthy


@app.api_route(PREFIX + '/api/v1/resource-node/probe', methods=['GET', 'HEAD'])
async def probe(request: Request):
    if not await origin_ready(request.app.state.client):
        raise HTTPException(503, 'Resource origin unavailable')
    return Response(PROBE_BODY if request.method == 'GET' else b'',
        media_type='application/octet-stream', headers={
            'Content-Length': str(len(PROBE_BODY)), 'Cache-Control': 'no-store',
            'X-BobTV-Probe': PROBE_VERSION, 'X-BobTV-Node': 'cndrp'})


@app.api_route(PREFIX + '/{path:path}', methods=['GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS'])
async def relay(path: str, request: Request):
    path = '/' + path
    query = request.scope['query_string'].decode('ascii')
    if not allowed(path, query, request.method):
        raise HTTPException(403, 'Resource path unavailable; video requires direct connection')
    body = bytearray()
    async for part in request.stream():
        body.extend(part)
        if len(body) > MAX_UPLOAD: raise HTTPException(413, 'Upload too large')
    address = str(ipaddress.ip_address(request.client.host))
    stamp = str(int(time.time()))
    # Do not trust forwarding/authentication fields provided by the caller.
    headers = {key: value for key, value in request.headers.items() if key.lower() in {
        'accept', 'content-type', 'authorization', 'user-agent', 'range', 'if-range',
        'if-none-match', 'if-modified-since', 'idempotency-key'}}
    headers.update({'Accept-Encoding': 'identity', 'Host': 'bobtv.briconbric.com',
        'X-BobTV-Relay-Node': 'cndrp', 'X-BobTV-Relay-Client': address,
        'X-BobTV-Relay-Time': stamp,
        'X-BobTV-Relay-Auth': signature(request.app.state.secret, request.method, path, address, stamp)})
    target = origin_url(path) + ('?' + query if query else '')
    client = request.app.state.client
    try:
        outgoing = client.build_request(request.method, target, headers=headers,
            content=bytes(body), extensions=origin_extensions())
        upstream = await client.send(outgoing, stream=True)
    except httpx.HTTPError:
        raise HTTPException(502, 'Resource origin connection failed') from None
    # Redirects must never leak clients to an external origin or GitHub.
    if 300 <= upstream.status_code < 400 and upstream.status_code != 304:
        await upstream.aclose()
        raise HTTPException(502, 'Resource origin redirect rejected')
    kept = {key: value for key, value in upstream.headers.items() if key.lower() in {
        'content-type', 'content-length', 'content-encoding', 'content-range',
        'accept-ranges', 'content-disposition', 'etag', 'last-modified', 'retry-after',
        'cache-control', 'vary'}}
    kept['X-BobTV-Node'] = 'cndrp'
    # Public response bodies retain canonical origins and publisher signatures.
    # Transport rewriting belongs to the client, not inside signed manifests.
    return StreamingResponse(upstream.aiter_raw(), status_code=upstream.status_code,
        headers=kept, background=BackgroundTask(upstream.aclose))
