"""Serve only update packages listed by a verified platform manifest."""

import json
import os
import re
from pathlib import Path

from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse, JSONResponse

DATA = Path(os.environ.get("BOBTV_DATA_DIR", Path(__file__).resolve().parent / "data"))
PLATFORMS = {"windows-x64", "macos-x64", "macos-arm64"}
FILENAME = re.compile(r"^BobTV-[A-Za-z0-9.+_-]+\.zip$")
router = APIRouter(prefix="/updates")


@router.get("/{platform}/latest.json")
def latest(platform: str):
    if platform not in PLATFORMS:
        raise HTTPException(404)
    path = DATA / "updates" / platform / "latest.json"
    if not path.is_file():
        raise HTTPException(404)
    return JSONResponse(json.loads(path.read_text(encoding="utf-8")),
                        headers={"Cache-Control": "no-store"})


@router.get("/files/{filename}")
def archive(filename: str):
    if not FILENAME.fullmatch(filename):
        raise HTTPException(404)
    approved_path = DATA / "updates" / "approved.json"
    try:
        approved = json.loads(approved_path.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        raise HTTPException(404)
    path = DATA / "updates" / "files" / filename
    if not isinstance(approved, dict) or filename not in approved or not path.is_file():
        raise HTTPException(404)
    return FileResponse(path, filename=filename, media_type="application/zip",
                        headers={"Cache-Control": "public, max-age=86400"})
