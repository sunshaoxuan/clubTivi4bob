"""Versioned private diagnostic ingestion, with no payload download route."""
import hashlib
import hmac
import os
from pathlib import Path
import sqlite3
import time

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

from diagnostic_store import DiagnosticStore, StoreLimit, MAX_BODY

router = APIRouter(prefix='/api/v1/diagnostics/batches')


def store():
    root = Path(os.environ.get('BOBTV_DATA_DIR', Path(__file__).parent / 'data'))
    return DiagnosticStore(Path(os.environ.get('BOBTV_DIAGNOSTICS_DIR', root / 'diagnostics-v2')))


async def read_batch(request):
    if request.headers.get('content-type', '').split(';')[0] != 'application/json':
        raise HTTPException(415, 'Expected diagnostic JSON')
    # Compressed bodies are deliberately unsupported: the byte ceiling cannot
    # be evaded with a decompression bomb.
    if request.headers.get('content-encoding', 'identity') != 'identity':
        raise HTTPException(415, 'Compressed diagnostics are unsupported')
    body = bytearray()
    async for part in request.stream():
        body.extend(part)
        if len(body) > MAX_BODY:
            raise HTTPException(413, 'Diagnostic batch exceeds byte limit')
    return bytes(body)


@router.post('')
async def upload(request: Request):
    body = await read_batch(request)
    from network_routes import _secret
    root = Path(os.environ.get('BOBTV_DATA_DIR', Path(__file__).parent / 'data'))
    peer = request.client.host if request.client else 'unknown'
    quota = hmac.new(_secret(root), (str(int(time.time()) // 86400) + ':' + peer).encode(), hashlib.sha256).hexdigest()
    try:
        receipt = await run_in_threadpool(store().put, body, quota=quota)
    except (ValueError, TypeError, OverflowError):
        raise HTTPException(422, 'Invalid structured diagnostics') from None
    except StoreLimit:
        raise HTTPException(429, 'Diagnostic quota reached', headers={'Retry-After': '3600'}) from None
    except (sqlite3.OperationalError, OSError):
        raise HTTPException(503, 'Diagnostic store temporarily busy', headers={
            'Retry-After': '30', 'Cache-Control': 'private, no-store'}) from None
    return JSONResponse(receipt, status_code=200 if receipt['duplicate'] else 201,
                        headers={'Cache-Control': 'private, no-store'})


@router.get('/{digest}')
async def receipt(digest: str):
    try:
        value = await run_in_threadpool(store().receipt, digest)
    except (sqlite3.OperationalError, OSError):
        raise HTTPException(503, 'Diagnostic store temporarily busy', headers={
            'Retry-After': '30', 'Cache-Control': 'private, no-store'}) from None
    if not value:
        raise HTTPException(404, 'Diagnostic receipt unavailable')
    return JSONResponse(value, headers={'Cache-Control': 'private, no-store'})
