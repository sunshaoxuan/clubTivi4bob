"""Validate and atomically publish a reviewed BobTV channel catalog.

Usage: python publish_channel_catalog.py catalog.json
The input contains schemaVersion, version, categories, and channels as
described in docs/channel-catalog-sync.md. Empty catalogs are rejected so a
mistaken publication cannot erase a working client catalog.
"""

import gzip
import hashlib
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from channel_catalog import DATA, DIRECTORY
from source_registry import validate_public_url
from catalog_inventory import validate_media_url

IDENTIFIER = re.compile(r"^[a-z0-9][a-z0-9-]{0,79}$")
MAX_CHANNELS = 10000
MAX_ROUTES = 100000
MAX_COMPRESSED = 32 * 1024 * 1024


def validate(payload):
    if not isinstance(payload, dict) or set(payload) != {
        "schemaVersion", "version", "categories", "channels"
    } or payload["schemaVersion"] != 1:
        raise ValueError("Unsupported channel catalog schema")
    version = payload["version"]
    if not isinstance(version, str) or not 1 <= len(version) <= 80 or not re.fullmatch(r"[A-Za-z0-9._:-]+", version):
        raise ValueError("Invalid catalog version")
    categories = payload["categories"]
    channels = payload["channels"]
    if not isinstance(categories, list) or not isinstance(channels, list) or not 0 <= len(channels) <= MAX_CHANNELS:
        raise ValueError("Catalog needs reviewed channels")
    category_ids = set()
    for item in categories:
        if not isinstance(item, dict) or set(item) != {"id", "parentId", "name", "sortOrder"}:
            raise ValueError("Invalid category")
        category_id = item["id"]
        if not isinstance(category_id, str) or not IDENTIFIER.fullmatch(category_id) or category_id in category_ids:
            raise ValueError("Duplicate or invalid category ID")
        if not isinstance(item["name"], str) or not 1 <= len(item["name"]) <= 64 or type(item["sortOrder"]) is not int:
            raise ValueError("Invalid category metadata")
        category_ids.add(category_id)
    for item in categories:
        parent = item["parentId"]
        if parent is not None and (parent not in category_ids or parent == item["id"]):
            raise ValueError("Unknown category parent")
    parent_by_id = {item["id"]: item["parentId"] for item in categories}
    for category_id in category_ids:
        seen = set()
        current = category_id
        while current is not None:
            if current in seen:
                raise ValueError("Category cycle")
            seen.add(current)
            current = parent_by_id[current]
    channel_ids = set()
    route_ids = set()
    route_urls = set()
    for channel in channels:
        required = {"id", "name", "categoryId", "countryCode", "regionCode", "sortOrder", "epgId", "logoUrl", "routes"}
        if not isinstance(channel, dict) or set(channel) != required:
            raise ValueError("Invalid channel")
        channel_id = channel["id"]
        if not isinstance(channel_id, str) or not IDENTIFIER.fullmatch(channel_id) or channel_id in channel_ids:
            raise ValueError("Duplicate or invalid channel ID")
        if channel["categoryId"] not in category_ids or not isinstance(channel["name"], str) or not 1 <= len(channel["name"]) <= 128:
            raise ValueError("Invalid channel classification")
        if type(channel["sortOrder"]) is not int or not isinstance(channel["routes"], list) or not channel["routes"]:
            raise ValueError("Invalid channel routes")
        for field in ("countryCode", "regionCode", "epgId", "logoUrl"):
            if channel[field] is not None and not isinstance(channel[field], str):
                raise ValueError("Invalid optional channel metadata")
        if channel["logoUrl"] is not None:
            validate_public_url(channel["logoUrl"])
        channel_ids.add(channel_id)
        for route in channel["routes"]:
            if not isinstance(route, dict) or set(route) - {'revision'} != {"id", "url", "source", "lastPlayableAt", "healthScore"}:
                raise ValueError("Invalid route")
            if 'revision' in route and (type(route['revision']) is not int or route['revision'] < 0):
                raise ValueError('Invalid route revision')
            route_id = route["id"]
            if not isinstance(route_id, str) or not IDENTIFIER.fullmatch(route_id) or route_id in route_ids:
                raise ValueError("Duplicate or invalid route ID")
            canonical = validate_media_url(route["url"])
            if canonical in route_urls:
                raise ValueError('Duplicate route endpoint')
            route_urls.add(canonical)
            if not isinstance(route["source"], str) or not 1 <= len(route["source"]) <= 128:
                raise ValueError("Invalid route provenance")
            if route["lastPlayableAt"] is not None and not isinstance(route["lastPlayableAt"], str):
                raise ValueError("Invalid route verification time")
            if type(route["healthScore"]) not in (int, float) or not 0 <= route["healthScore"] <= 1:
                raise ValueError("Invalid route health score")
            route_ids.add(route_id)
            if len(route_ids) > MAX_ROUTES:
                raise ValueError("Too many routes")
    return len(channel_ids), len(route_ids)


def _atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".catalog-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def publish(payload, data_dir=DATA):
    channel_count, route_count = validate(payload)
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    compressed = gzip.compress(raw, mtime=0)
    if len(compressed) > MAX_COMPRESSED:
        raise ValueError("Compressed snapshot exceeds 32 MiB")
    digest = hashlib.sha256(compressed).hexdigest()
    directory = Path(data_dir) / DIRECTORY
    snapshot = directory / "snapshots" / f"{digest}.json.gz"
    if not snapshot.exists():
        _atomic_write(snapshot, compressed)
    manifest = {
        "schemaVersion": 1,
        "version": payload["version"],
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "channelCount": channel_count,
        "routeCount": route_count,
        "snapshotUrl": f"/api/v1/channel-catalog/snapshots/{digest}.json.gz",
        "compressedBytes": len(compressed),
        "sha256": digest,
    }
    _atomic_write(directory / "manifest.json", json.dumps(manifest, separators=(",", ":")).encode("utf-8"))
    return manifest


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python publish_channel_catalog.py catalog.json")
    result = publish(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")))
    print(json.dumps(result, ensure_ascii=False))
