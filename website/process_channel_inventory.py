"""Verify contributed public routes and publish the shared classified catalog."""
import concurrent.futures
import fcntl
import gzip
import hashlib
import http.client
import ipaddress
import json
import re
import socket
import time
import unicodedata
import urllib.request
from datetime import datetime, timezone
from urllib.parse import urljoin, urlsplit

from catalog_inventory import DATA, database, ingest, validate_media_url
from route_identity import canonical_route_url
from publish_channel_catalog import publish


def _public_target(url):
    validate_media_url(url)
    parsed = urlsplit(url)
    addresses = socket.getaddrinfo(parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80), type=socket.SOCK_STREAM)
    if not addresses or any(not ipaddress.ip_address(item[4][0]).is_global for item in addresses):
        raise ValueError("Non-public resolved address")


def _public_socket(host, port, timeout, source_address):
    addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    if not addresses or any(not ipaddress.ip_address(item[4][0]).is_global for item in addresses):
        raise ValueError("Non-public connection address")
    error = None
    for item in addresses:
        try:
            # Connect to the checked numeric address, avoiding a second DNS
            # resolution between validation and the actual socket connection.
            return socket.create_connection((item[4][0], port), timeout, source_address)
        except OSError as exc:
            error = exc
    raise error or OSError("No usable public address")


class _HTTPConnection(http.client.HTTPConnection):
    def connect(self):
        if self._tunnel_host: raise ValueError("Proxy tunnels are not supported")
        self.sock = _public_socket(self.host, self.port, self.timeout, self.source_address)


class _HTTPSConnection(http.client.HTTPSConnection):
    def connect(self):
        if self._tunnel_host: raise ValueError("Proxy tunnels are not supported")
        sock = _public_socket(self.host, self.port, self.timeout, self.source_address)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


class _HTTPHandler(urllib.request.HTTPHandler):
    def http_open(self, req):
        return self.do_open(_HTTPConnection, req)


class _HTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(_HTTPSConnection, req, context=self._context)


class _Redirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        _public_target(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def probe(url):
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _Redirect(), _HTTPHandler(), _HTTPSHandler())
        for depth in range(4):
            _public_target(url)
            request = urllib.request.Request(url, headers={"User-Agent": "BobTV-Catalog/1.0", "Range": "bytes=0-65535"})
            with opener.open(request, timeout=6) as response:
                body = response.read(65536)
                base = response.url
            if body.lstrip().startswith(b"#EXTM3U"):
                text = body.decode("utf-8-sig")
                targets = [line.strip() for line in text.splitlines() if line.strip() and not line.startswith("#")]
                if not targets: return False
                # Follow the newest segment, avoiding obsolete sliding-window URLs.
                url = urljoin(base, targets[-1] if "#EXTINF" in text else targets[0])
                continue
            return len(body) >= 512 and (body[:1] == b"G" or b"ftyp" in body[:32] or b"styp" in body[:32] or b"moof" in body[:32] or b"ID3" in body[:16] or body[:1] == b"\xff")
    except Exception:
        return False
    return False


def _current(data_dir):
    path = data_dir / "channel-catalog" / "manifest.json"
    if not path.exists(): return None
    manifest = json.loads(path.read_text())
    snapshot = data_dir / "channel-catalog" / "snapshots" / (manifest["sha256"] + ".json.gz")
    return json.loads(gzip.decompress(snapshot.read_bytes()))


def _group(category_id, categories):
    parts = []
    while category_id:
        item = categories[category_id]
        parts.insert(0, item["name"])
        category_id = item["parentId"]
    return " / ".join(parts)


def _identity(name):
    name = unicodedata.normalize("NFKC", name).strip()
    cctv = re.match(r"^CCTV[\s_-]*(\d{1,2})(\+)?(?=$|[\s_-]|[\u4e00-\u9fff])", name, re.I)
    if cctv:
        quality = re.search(r"\b([48]K)\b", name, re.I)
        return "CCTV-" + str(int(cctv[1])) + (cctv[2] or "") + (" " + quality[1].upper() if quality else "")
    return re.sub(r"\s+(HD|FHD|SD|1080P|720P)$", "", name, flags=re.I)


def _public_media(url):
    try:
        validate_media_url(url)
        parsed = urlsplit(url)
        return not parsed.path.lower().endswith(('.html', '.htm'))
    except (ValueError, TypeError):
        return False


def _public_logo(url):
    if not url: return None
    try:
        from source_registry import validate_public_url
        validate_public_url(url)
        return url
    except (ValueError, TypeError):
        return None


def _television_media(name, url):
    # Match the client rejection policy before atomic catalog publication.
    if not _public_media(url): return False
    identity = name.strip().lower()
    if identity in ('直播中国', '熊猫直播') or re.fullmatch(r'咪咕直播\d+', identity):
        return False
    if any(term in identity for term in ('游戏风云', '电竞', '购物', '商城')):
        return False
    host = (urlsplit(url).hostname or '').lower()
    if host == '107.173.156.246': return False
    return not host.endswith(('.huya.com', '.douyu.com', '.douyucdn.cn',
        '.bilivideo.com', '.acgvideo.com', '.kwimgs.com'))


def _verify_pending(data_dir, limit, verifier):
    now=int(time.time())
    with database(data_dir) as conn:
        pending=conn.execute("SELECT digest,url FROM routes WHERE blocked=0 AND deleted=0 AND (checked_at IS NULL OR checked_at<?) ORDER BY checked_at IS NULL DESC, group_name='中国 / 央视' DESC, playable_at IS NOT NULL DESC, failures ASC, checked_at ASC LIMIT ?",(now-6*3600,limit)).fetchall()
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results=list(pool.map(verifier,[row['url'] for row in pending]))
    # A disconnected verifier must not mark the entire shared catalog dead.
    if len(results)>=8 and not any(results): return len(pending)
    with database(data_dir) as conn:
        for row,success in zip(pending,results):
            conn.execute("UPDATE routes SET checked_at=?,success_at=CASE WHEN ? THEN ? ELSE success_at END,failures=CASE WHEN ? THEN 0 ELSE failures+1 END WHERE digest=?",(now,success,now,success,row['digest']))
    return len(pending)


def process(data_dir=DATA, limit=120, verifier=probe):
    data_dir.mkdir(parents=True, exist_ok=True)
    # Network verification never holds the publication lock. Metadata edits,
    # weights and tombstones can publish while a slow route is being checked.
    checked=_verify_pending(data_dir,limit,verifier) if limit else 0
    with (data_dir / "catalog-process.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = _current(data_dir)
        with database(data_dir) as conn:
            empty = conn.execute("SELECT count(*) FROM routes").fetchone()[0] == 0
        if empty and current:
            categories = {item["id"]: item for item in current["categories"]}
            rows = [{"name": channel["name"], "url": route["url"], "group": _group(channel["categoryId"], categories), "source": route["source"], "epgId": channel["epgId"], "logoUrl": channel["logoUrl"], "playableAt": None, "blocked": False} for channel in current["channels"] for route in channel["routes"]]
            ingest(rows, "0" * 64, data_dir)
            with database(data_dir) as conn:
                conn.execute("UPDATE routes SET success_at=?,checked_at=?", (int(time.time()), int(time.time())))
        now = int(time.time())
        with database(data_dir) as conn:
            rows = conn.execute("SELECT * FROM routes WHERE blocked=0 AND deleted=0 AND success_at>=? AND failures<3 ORDER BY group_name,name,digest", (now - 7 * 86400,)).fetchall()
            blocked = {canonical_route_url(row[0]) for row in conn.execute("SELECT url FROM routes WHERE blocked=1 OR deleted=1")}
        categories = {}
        channels = {}
        for row in rows:
            if not _television_media(row["name"], row["url"]): continue
            path = row["group_name"].split(" / ")[:4]
            if path[0] not in ("中国", "国际", "其他", "广播", "数字"): path = ["其他"]
            parent = None
            for depth, name in enumerate(path):
                identity = "category-" + hashlib.sha256(" / ".join(path[:depth+1]).encode()).hexdigest()[:24]
                categories[identity] = {"id": identity, "parentId": parent, "name": name, "sortOrder": 0 if name == "中国" else 1 if name == "央视" else 10}
                parent = identity
            name = _identity(row["name"])
            identity = "channel-" + hashlib.sha256((row["group_name"] + "\n" + name).encode()).hexdigest()[:24]
            channel = channels.setdefault(identity, {"id": identity, "name": name, "categoryId": parent, "countryCode": "CN" if path[0] == "中国" else None, "regionCode": None, "sortOrder": len(channels), "epgId": row["epg_id"], "logoUrl": _public_logo(row["logo_url"]), "routes": []})
            if not channel["logoUrl"]: channel["logoUrl"] = _public_logo(row["logo_url"])
            if not channel["epgId"]: channel["epgId"] = row["epg_id"]
            confidence = min(1, (row['success_votes'] + row['failure_votes']) / 10)
            learned = (row['success_votes'] + 4) / (row['success_votes'] + row['failure_votes'] + 5)
            score = max(.1, .8 - row['failures'] * .2) * (1-confidence) + learned * confidence
            channel["routes"].append({"id": "route-" + row["digest"][:24], "url": row["url"], "source": row["source"], "lastPlayableAt": datetime.fromtimestamp(row["success_at"], timezone.utc).isoformat().replace("+00:00", "Z"), "healthScore": score, 'revision':row['revision']})
        # Keep prior reviewed routes until their inventory record is verified.
        if current:
            inventory_urls = {canonical_route_url(row["url"]) for row in rows}
            seen_urls = set(inventory_urls)
            for channel in current["channels"]:
                routes = []
                for route in channel['routes']:
                    url = canonical_route_url(route['url'])
                    if not _television_media(channel['name'], url) or url in blocked or url in seen_urls:
                        continue
                    seen_urls.add(url)
                    routes.append({**route, 'url': url, 'id': 'route-' + hashlib.sha256(url.encode()).hexdigest()[:24]})
                if routes:
                    with database(data_dir) as conn:
                        routes = [route for route in routes if not conn.execute("SELECT 1 FROM routes WHERE url=? AND (failures>=3 OR (success_at IS NOT NULL AND success_at<?))", (route["url"],now-7*86400)).fetchone()]
                if routes:
                    channels[channel["id"]] = {**channel, "routes": routes}
                    for item in current["categories"]: categories.setdefault(item["id"], item)
        if not channels and not current: return {"checked": checked, "published": False}
        used = {channel['categoryId'] for channel in channels.values()}
        for identity in list(used):
            parent = categories[identity]['parentId']
            while parent:
                used.add(parent)
                parent = categories[parent]['parentId']
        categories = {key:value for key,value in categories.items() if key in used}
        payload = {"schemaVersion": 1, "version": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"), "categories": list(categories.values()), "channels": list(channels.values())}
        if current and current["categories"] == payload["categories"] and current["channels"] == payload["channels"]:
            return {"checked": checked, "published": False}
        manifest = publish(payload, data_dir)
        return {"checked": checked, "published": True, **manifest}


if __name__ == "__main__":
    print(json.dumps(process(), ensure_ascii=False))
