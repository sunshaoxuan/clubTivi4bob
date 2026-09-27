"""Immutable, preclassified channel snapshots for BobTV clients."""

import hashlib
import json
import os
import re
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, Response

DATA = Path(os.environ.get("BOBTV_DATA_DIR", Path(__file__).resolve().parent / "data"))
DIRECTORY = "channel-catalog"
DIGEST = re.compile(r"^[a-f0-9]{64}$")
router = APIRouter(prefix="/api/v1/channel-catalog")


@router.get("/manifest")
def manifest(request: Request):
    path = DATA / DIRECTORY / "manifest.json"
    if not path.is_file():
        return JSONResponse(
            {"schemaVersion": 1, "version": None, "channelCount": 0, "routeCount": 0},
            headers={"Cache-Control": "no-store"},
        )
    content = path.read_bytes()
    etag = f'"{hashlib.sha256(content).hexdigest()}"'
    if request.headers.get("if-none-match") == etag:
        return Response(status_code=304, headers={"ETag": etag, "Cache-Control": "no-cache"})
    return Response(
        content, media_type="application/json",
        headers={"ETag": etag, "Cache-Control": "no-cache"},
    )


@router.get("/snapshots/{digest}.json.gz")
def snapshot(digest: str):
    if not DIGEST.fullmatch(digest):
        raise HTTPException(404)
    manifest_path = DATA / DIRECTORY / "manifest.json"
    if not manifest_path.is_file():
        raise HTTPException(404)
    try:
        current = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise HTTPException(503, "Catalog manifest unavailable") from None
    if current.get("sha256") != digest:
        raise HTTPException(404)
    path = DATA / DIRECTORY / "snapshots" / f"{digest}.json.gz"
    if not path.is_file():
        raise HTTPException(503, "Catalog snapshot unavailable")
    return FileResponse(
        path, media_type="application/gzip",
        headers={"Cache-Control": "public, max-age=31536000, immutable"},
    )
