"""Bounded upstream imports and public, network-scoped route discovery."""
import fcntl
import hashlib
import ipaddress
import json
import logging
import re
import time
import urllib.request
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import JSONResponse, PlainTextResponse
from ipytv.channel import from_playlist_entry

from catalog_inventory import DATA, database as inventory_database, validate_media_url
from channel_matching import migrate

REGISTRY = json.loads(Path(__file__).with_name("public_sources.json").read_text(encoding="utf-8"))
SOURCES = {source["id"]: source for source in REGISTRY["sources"]}
MAX_BYTES = 8 * 1024 * 1024
MAX_ENTRIES = 40000
router = APIRouter(prefix="/api/v1/channel-catalog")
# The parser can log malformed rows verbatim, including upstream credentials.
logging.getLogger("ipytv.channel").disabled = True


@contextmanager
def database(data_dir=None):
    with inventory_database(data_dir) as conn:
        migrate(conn)
        yield conn


def validate_access(access):
    if not isinstance(access, dict) or set(access) != {
        "geoStatus", "allowedCountries", "network", "availability", "evidenceUrl"
    }:
        raise ValueError("Invalid route access metadata")
    if access["geoStatus"] not in ("unknown", "restricted") or access["allowedCountries"] is not None:
        raise ValueError("Unproven geographic allowlist")
    if access["network"] not in ("public", "ipv6", "operator-multicast"):
        raise ValueError("Invalid network requirement")
    if access["availability"] not in ("unknown", "not-24-7"):
        raise ValueError("Invalid availability")
    if access["evidenceUrl"] not in {s["repositoryUrl"] for s in SOURCES.values()}:
        raise ValueError("Unknown restriction evidence")


def _candidate_url(url):
    if not isinstance(url, str) or len(url) > 2048 or any(ord(c) <= 32 for c in url) or "|" in url:
        raise ValueError("Invalid candidate")
    parsed = urlsplit(url)
    if parsed.scheme in ("rtp", "udp"):
        address = ipaddress.ip_address(parsed.hostname or "")
        if (address.version != 4 or address not in ipaddress.ip_network("239.0.0.0/8")
                or parsed.username or parsed.password or parsed.query or parsed.fragment
                or parsed.path not in ("", "/") or not parsed.port):
            raise ValueError("Unsupported multicast endpoint")
        return f"{parsed.scheme}://{address}:{parsed.port}", "operator-multicast"
    # Reject additional signed-link keys as well as the shared credential filter.
    if any(re.search(r"sign|credential|session|cookie|ticket|username|passwd|^(key|user|pass|pwd|sig|jwt)$", key, re.I)
           for key, _ in parse_qsl(parsed.query)):
        raise ValueError("Credential-bearing candidate")
    url = validate_media_url(url)
    try:
        ipv6 = ipaddress.ip_address(parsed.hostname).version == 6
    except ValueError:
        ipv6 = False
    return url, "ipv6" if ipv6 else "public"


def _group(name, attributes, extras):
    from channel_taxonomy import valid_path
    group = attributes.get("group-title", "").strip()
    if not group:
        group = next((line.partition(":")[2].strip() for line in extras if line.startswith("#EXTGRP:")), "")
    if valid_path(group):
        return group
    if re.match(r"^CCTV[\s_-]*\d", name, re.I) or "央视" in group:
        return "中国 / 央视"
    if "卫视" in group:
        return "中国 / 卫视"
    return "其他" + (" / " + group if group else "")


def parse_playlist(body, source):
    if not isinstance(body, bytes) or len(body) > MAX_BYTES:
        raise ValueError("Playlist exceeds byte limit")
    text = body.decode("utf-8-sig")
    lines = text.splitlines()
    if not lines or not re.match(r"^#EXTM3U(?:\s|$)", lines[0]) or any(len(line) > 8192 for line in lines):
        raise ValueError("Invalid playlist header or line")
    entries = []
    current = None
    for raw in lines[1:]:
        line = raw.strip()
        if line.startswith("#EXTINF:"):
            if current is not None:
                entries.append(current)
            current = [line]
        elif line and current is not None:
            current.append(line)
        if len(entries) > MAX_ENTRIES:
            raise ValueError("Too many playlist entries")
    if current is not None:
        entries.append(current)
    if not entries or len(entries) > MAX_ENTRIES:
        raise ValueError("Empty or oversized playlist")
    if any(len([line for line in entry[1:] if not line.startswith("#")]) != 1 for entry in entries):
        raise ValueError("Incomplete playlist entry")
    candidates = {}
    skipped = 0
    for entry in entries:
        try:
            item = from_playlist_entry(entry)
            if any(not line.startswith("#EXTGRP:") for line in item.extras):
                raise ValueError("Unsupported player headers or DRM options")
            name = re.sub(r"\s*\[(?:Geo-blocked|Not 24/7)\]", "", item.name, flags=re.I).strip()
            group = _group(name, item.attributes, item.extras)
            if not all(1 <= len(value) <= limit and not any(ord(c) < 32 for c in value)
                       for value, limit in ((name, 128), (group, 192))):
                raise ValueError("Invalid channel metadata")
            if any(not 1 <= len(part) <= 64 for part in group.split(" / ")):
                raise ValueError("Invalid category name")
            url, network = _candidate_url(item.url)
            if network != "operator-multicast":
                from process_channel_inventory import _television_media
                if not _television_media(name, url):
                    raise ValueError("Non-television endpoint")
            access = {
                "geoStatus": "restricted" if "[geo-blocked]" in item.name.lower() else "unknown",
                "allowedCountries": None,
                "network": network if network != "public" else source["network"],
                "availability": "not-24-7" if "[not 24/7]" in item.name.lower() else "unknown",
                "evidenceUrl": source["repositoryUrl"],
            }
            validate_access(access)
            logo = item.attributes.get("tvg-logo") or None
            if logo:
                try:
                    logo, logo_network = _candidate_url(logo)
                    if logo_network == "operator-multicast":
                        logo = None
                except ValueError:
                    logo = None
            epg = item.attributes.get("tvg-id") or None
            if epg and (len(epg) > 128 or any(ord(c) < 32 for c in epg)):
                epg = None
            digest = hashlib.sha256(url.encode()).hexdigest()
            existing = candidates.get(digest)
            if existing:
                if access["geoStatus"] == "restricted":
                    existing["access"]["geoStatus"] = "restricted"
                if access["availability"] == "not-24-7":
                    existing["access"]["availability"] = "not-24-7"
                continue
            candidates[digest] = dict(digest=digest, name=name, url=url, group=group,
                                      access=access, epg=epg, logo=logo)
        except (ValueError, TypeError):
            skipped += 1
    if not candidates:
        raise ValueError("No safe candidates")
    return list(candidates.values()), len(entries), skipped


def fetch_playlist(url):
    from process_channel_inventory import _public_target, _Redirect, _HTTPHandler, _HTTPSHandler
    _public_target(url)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _Redirect(), _HTTPHandler(), _HTTPSHandler())
    request = urllib.request.Request(url, headers={"User-Agent": "BobTV-Catalog/1.0", "Accept-Encoding": "identity"})
    start = time.monotonic()
    with opener.open(request, timeout=10) as response:
        if response.status != 200 or response.headers.get("Content-Encoding", "identity") != "identity":
            raise ValueError("Unexpected playlist response")
        size = response.headers.get("Content-Length")
        if size and (not size.isdigit() or int(size) > MAX_BYTES):
            raise ValueError("Oversized playlist response")
        body = bytearray()
        while True:
            if time.monotonic() - start > 60:
                raise ValueError("Playlist read deadline")
            chunk = response.read(min(65536, MAX_BYTES + 1 - len(body)))
            if not chunk:
                break
            body.extend(chunk)
            if len(body) > MAX_BYTES:
                raise ValueError("Oversized playlist response")
        if size and len(body) != int(size):
            raise ValueError("Incomplete playlist response")
        return bytes(body)


def _store(source, candidates, discovered, skipped, data_dir, now):
    with database(data_dir) as conn:
        new_routes = [item for item in candidates if item["access"]["network"] != "operator-multicast"
                      and not conn.execute("SELECT 1 FROM routes WHERE digest=?", (item["digest"],)).fetchone()]
        if conn.execute("SELECT count(*) FROM routes").fetchone()[0] + len(new_routes) > 250000:
            raise ValueError("Inventory capacity reached")
        conn.execute("UPDATE public_source_routes SET active=0 WHERE source_id=?", (source["id"],))
        conn.execute("DELETE FROM public_source_routes WHERE source_id=? AND digest NOT IN (SELECT digest FROM routes)", (source["id"],))
        for item in candidates:
            conn.execute("""INSERT INTO public_source_routes VALUES(?,?,?,?,?,?,1)
                ON CONFLICT(source_id,digest) DO UPDATE SET url=excluded.url,name=excluded.name,
                group_name=excluded.group_name,access=excluded.access,active=1""", (
                source["id"], item["digest"], item["url"], item["name"], item["group"], json.dumps(item["access"])))
            if item["access"]["network"] == "operator-multicast":
                continue
            conn.execute("""INSERT INTO routes(digest,name,url,group_name,source,epg_id,logo_url,received)
                VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(digest) DO UPDATE SET received=excluded.received""",
                (item["digest"], item["name"], item["url"], item["group"], source["name"], item["epg"], item["logo"], now))
            conn.execute("INSERT OR IGNORE INTO route_origins VALUES(?,?)", (item["digest"], source["name"]))
        conn.execute("""INSERT INTO public_source_refreshes VALUES(?,?,?,'ok',?,?,?)
            ON CONFLICT(source_id) DO UPDATE SET attempted_at=excluded.attempted_at,
            succeeded_at=excluded.succeeded_at,status='ok',discovered=excluded.discovered,
            retained=excluded.retained,skipped=excluded.skipped""",
            (source["id"], now, now, discovered, len(candidates), skipped))


def refresh(data_dir=DATA, fetcher=fetch_playlist, force=False):
    directory = Path(data_dir)
    directory.mkdir(parents=True, exist_ok=True)
    results = []
    with (directory / "public-sources.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for source in SOURCES.values():
            now = int(time.time())
            with database(directory) as conn:
                previous = conn.execute("SELECT * FROM public_source_refreshes WHERE source_id=?", (source["id"],)).fetchone()
            interval = 6 * 3600 if previous and previous["status"] == "ok" else 3600
            if not force and previous and now - previous["attempted_at"] < interval:
                results.append({"sourceId": source["id"], "status": "not-due"})
                continue
            try:
                candidates, discovered, skipped = parse_playlist(fetcher(source["playlistUrl"]), source)
                _store(source, candidates, discovered, skipped, directory, now)
                results.append({"sourceId": source["id"], "status": "ok", "discovered": discovered,
                                "retained": len(candidates), "skipped": skipped})
            except Exception:
                # Never persist exception text, playlist bodies, or credentials.
                with database(directory) as conn:
                    conn.execute("""INSERT INTO public_source_refreshes VALUES(?,?,NULL,'failed',0,0,0)
                        ON CONFLICT(source_id) DO UPDATE SET attempted_at=excluded.attempted_at,status='failed'""",
                        (source["id"], now))
                results.append({"sourceId": source["id"], "status": "failed"})
    return {"sources": results}


def origins_for(conn):
    result = {}
    for row in conn.execute("SELECT source_id,digest,access FROM public_source_routes ORDER BY source_id"):
        result.setdefault(row["digest"], []).append({"sourceId": row["source_id"], "access": json.loads(row["access"])})
    return result


@router.get("/sources")
def public_sources():
    with database(DATA) as conn:
        states = {row["source_id"]: dict(row) for row in conn.execute("SELECT * FROM public_source_refreshes")}
    return JSONResponse({"schemaVersion": 1, "sources": [
        {**source, "subscriptionUrl": f"/api/v1/channel-catalog/source-playlists/{source['id']}.m3u",
         "geoStatus": "unknown", "allowedCountries": None,
         "lastRefresh": states.get(source["id"])} for source in SOURCES.values()],
        "resources": REGISTRY["resources"]}, headers={"Cache-Control": "no-store"})


@router.get("/source-routes")
def source_routes(sourceId: str, after: str = Query("", pattern=r"^(?:[a-f0-9]{64})?$"),
                  limit: int = Query(100, ge=1, le=200)):
    if sourceId not in SOURCES:
        raise HTTPException(404, "Unknown public source")
    with database(DATA) as conn:
        rows = conn.execute("""SELECT p.*,r.checked_at,r.success_at,r.failures,m.channel_id,m.state AS match_state,m.reason AS match_reason FROM public_source_routes p
            LEFT JOIN routes r ON r.digest=p.digest
            LEFT JOIN catalog_channel_routes m ON m.digest=p.digest
            WHERE p.source_id=? AND p.active=1 AND p.digest>? AND COALESCE(r.blocked,0)=0 AND COALESCE(r.deleted,0)=0
            ORDER BY p.digest LIMIT ?""", (sourceId, after, limit + 1)).fetchall()
    items = []
    for row in rows[:limit]:
        access = json.loads(row["access"])
        state = "candidate"
        if access["network"] == "operator-multicast":
            state = "network-required"
        elif row["success_at"] and row["success_at"] >= int(time.time()) - 7 * 86400 and row["failures"] < 3:
            state = "server-verified"
        elif row["checked_at"]:
            state = "server-unverified"
        items.append({"id": "route-" + row["digest"][:24], "name": row["name"], "url": row["url"],
                      "group": row["group_name"], "sourceId": sourceId, "access": access,
                      "channelId": row["channel_id"], "matching": {"state": row["match_state"] or "pending", "reason": row["match_reason"]},
                      "verification": {"scope": "catalog-server", "state": state,
                                       "checkedAt": row["checked_at"], "successAt": row["success_at"]}})
    return JSONResponse({"schemaVersion": 1, "routes": items,
                         "nextCursor": rows[limit - 1]["digest"] if len(rows) > limit else None},
                        headers={"Cache-Control": "no-store"})


@router.get("/source-playlists/{source_id}.m3u")
def source_playlist(source_id: str):
    if source_id not in SOURCES:
        raise HTTPException(404, "Unknown public source")
    with database(DATA) as conn:
        rows = conn.execute("""SELECT p.*,r.epg_id,r.logo_url FROM public_source_routes p
            LEFT JOIN routes r ON r.digest=p.digest
            WHERE p.source_id=? AND p.active=1 AND COALESCE(r.blocked,0)=0 AND COALESCE(r.deleted,0)=0
            ORDER BY p.digest LIMIT ?""", (source_id, MAX_ENTRIES)).fetchall()
    lines = ["#EXTM3U"]
    for row in rows:
        access = json.loads(row["access"])
        tags = []
        if access["geoStatus"] == "restricted":
            tags.append("Geo-blocked")
        if access["network"] == "ipv6":
            tags.append("IPv6")
        if access["network"] == "operator-multicast":
            tags.append("IPTV Multicast")
        if access["availability"] == "not-24-7":
            tags.append("Not 24/7")
        name = row["name"] + "".join(" [" + tag + "]" for tag in tags)
        attributes = {"bobtv-route-id": "route-" + row["digest"][:24], "group-title": row["group_name"],
                      "tvg-id": row["epg_id"], "tvg-logo": row["logo_url"]}
        metadata = " ".join(key + '="' + value.replace('"', "'") + '"'
                            for key, value in attributes.items() if value)
        lines.extend([f"#EXTINF:-1 {metadata},{name}", row["url"]])
    return PlainTextResponse("\n".join(lines) + "\n", media_type="audio/x-mpegurl",
                             headers={"Cache-Control": "no-store"})


if __name__ == "__main__":
    from channel_reference import refresh as refresh_reference
    reference_result = refresh_reference(DATA)
    result = refresh()
    result['channelReference'] = reference_result
    print(json.dumps(result, ensure_ascii=False))
    raise SystemExit(int(any(item["status"] == "failed" for item in result["sources"])))
