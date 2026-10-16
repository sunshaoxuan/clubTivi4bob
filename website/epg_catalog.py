"""Read-only EPG endpoints backed by one authoritative committed activation."""
from pathlib import Path
from functools import lru_cache
from contextlib import closing
import hashlib
import json
import re
import sqlite3

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, Response

from catalog_inventory import DATA
from epg_store import active_manifest
from epg_ingest import EpgError

router = APIRouter(prefix='/api/v1/epg')
DIRECTORY = Path(DATA) / 'epg' / 'public'
DATABASE = Path(DATA) / 'epg' / 'epg.sqlite3'


@lru_cache(maxsize=32)
def _checked_snapshot(path, digest, inode, size, modified_ns):
    # Immutable contents are hashed once per filesystem revision, never per card.
    if not 0 < size <= 8 * 1024 * 1024:
        raise EpgError('invalid_publication_snapshot')
    with Path(path).open('rb') as stream:
        body = stream.read(8 * 1024 * 1024 + 1)
    if len(body) != size or hashlib.sha256(body).hexdigest() != digest:
        raise EpgError('invalid_publication_snapshot')
    return True


def checked_snapshot(digest, expected_bytes=None):
    path = DIRECTORY / 'snapshots' / (digest + '.json.gz')
    if path.is_symlink() or path.parent.is_symlink() or not path.is_file():
        raise EpgError('publication_snapshot_unavailable')
    stat = path.stat()
    if expected_bytes is not None and stat.st_size != expected_bytes:
        raise EpgError('invalid_publication_snapshot')
    _checked_snapshot(str(path), digest, stat.st_ino, stat.st_size, stat.st_mtime_ns)
    return path


@router.get('/manifest')
def manifest(request: Request):
    headers = {'Cache-Control': 'no-store, max-age=0', 'Pragma': 'no-cache'}
    try:
        if not DATABASE.is_file():
            value = None
        else:
            with closing(sqlite3.connect(DATABASE.resolve().as_uri() + '?mode=ro', uri=True, timeout=2)) as conn:
                value = active_manifest(conn)
        if value is None:
            return JSONResponse({'schemaVersion': 1, 'version': None, 'channelCount': 0}, headers=headers)
        checked_snapshot(value['sha256'], value['compressedBytes'])
    except (EpgError, sqlite3.Error, OSError, ValueError):
        return JSONResponse({'error': 'epg_publication_unavailable'}, status_code=503, headers=headers)
    raw = json.dumps(value, sort_keys=True, separators=(',', ':')).encode()
    headers['ETag'] = '"' + hashlib.sha256(raw).hexdigest() + '"'
    if request.headers.get('if-none-match') == headers['ETag']:
        return Response(status_code=304, headers=headers)
    return Response(raw, media_type='application/json', headers=headers)


@router.get('/snapshots/{digest}.json.gz')
def snapshot(digest: str):
    if not re.fullmatch(r'[a-f0-9]{64}', digest):
        raise HTTPException(404)
    try:
        path = checked_snapshot(digest)
    except (EpgError, OSError):
        raise HTTPException(404)
    return FileResponse(path, media_type='application/gzip',
        headers={'Cache-Control': 'public, max-age=31536000, immutable'})
