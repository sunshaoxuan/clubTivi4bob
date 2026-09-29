"""Create a small, explicitly classified starter catalog from local checks.

Usage: python build_seed_catalog.py clubtivi.db output.json
The output is a publication candidate. Review and validate it before upload.
Only exact channel/host pairs below are eligible. A health scan is not proof
that a stream contains the advertised program.
"""

import hashlib
import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

from publish_channel_catalog import validate
from source_registry import validate_public_url


CATEGORIES = [
    ("cn", None, "中国", 10),
    ("cn-zhejiang", "cn", "浙江", 10),
    ("cn-hebei", "cn", "河北", 20),
    ("us", None, "美国", 20),
    ("th", None, "泰国", 30),
    ("kr", None, "韩国", 40),
    ("br", None, "巴西", 50),
    ("other", None, "其他地区", 90),
]

# Exact identity and publisher-host rules avoid substring-based classification.
CHANNELS = {
    **{name: ("cn-zhejiang", "CN", "ZJ", "cztv.com") for name in (
        "浙江新闻", "浙江经济", "浙江教科", "浙江国际", "浙江民生",
        "浙江民生休闲", "浙江钱江", "浙江钱江都市", "浙江公共新闻",
        "浙江教科影视", "浙江经视", "之江纪录",
    )},
    **{name: ("cn-hebei", "CN", "HE", "hebyun.com.cn") for name in (
        "邯郸公共频道", "邯郸科技教育", "清河经济综艺", "平泉综合",
    )},
    "CBS News": ("us", "US", None, "cbsnews.com"),
    "DLTV 2": ("th", "TH", None, "dltv.ac.th"),
    "DLTV 3": ("th", "TH", None, "dltv.ac.th"),
    "KTV": ("kr", "KR", None, "ktv.go.kr"),
    "Canal Gov": ("br", "BR", None, "ebc.com.br"),
    "Good TV": ("other", None, None, "streamingfast.net"),
    "Cloudflare TV": ("other", None, None, "cloudflare.tv"),
}


def build(database, now=None):
    now = now or datetime.now(timezone.utc)
    cutoff = int(now.timestamp()) - 7 * 86400
    result = {}
    with sqlite3.connect(f"file:{Path(database).resolve()}?mode=ro", uri=True) as conn:
        rows = conn.execute("""
            SELECT c.name, c.stream_url, MAX(s.last_success_at)
            FROM channels c
            JOIN stream_checks s ON s.provider_id = c.provider_id
                AND s.stream_url = c.stream_url
            LEFT JOIN blocked_stream_routes b ON b.stream_url = c.stream_url
            WHERE c.hidden = 0 AND c.stream_type = 'live'
                AND s.retired = 0 AND s.consecutive_failures = 0
                AND s.last_success_at >= ? AND b.stream_url IS NULL
            GROUP BY c.name, c.stream_url
        """, (cutoff,)).fetchall()
    for name, url, checked in rows:
        rule = CHANNELS.get(name)
        if rule is None:
            continue
        category, country, region, publisher = rule
        host = urlsplit(url).hostname or ""
        if host != publisher and not host.endswith("." + publisher):
            continue
        try:
            validate_public_url(url)
        except ValueError:
            continue
        channel = result.setdefault(name, {
            "id": "channel-" + hashlib.sha256(name.encode()).hexdigest()[:24],
            "name": name, "categoryId": category,
            "countryCode": country, "regionCode": region,
            "sortOrder": sorted(CHANNELS).index(name),
            "epgId": None, "logoUrl": None, "routes": [],
        })
        channel["routes"].append({
            "id": "route-" + hashlib.sha256(
                (name + "\n" + url).encode()).hexdigest()[:24],
            "url": url,
            "source": "BobTV health scan: " + host,
            "lastPlayableAt": datetime.fromtimestamp(
                checked, timezone.utc).isoformat().replace("+00:00", "Z"),
            "healthScore": 0.7,
        })
    payload = {
        "schemaVersion": 1,
        "version": now.strftime("%Y-%m-%dT%H:%M:%SZ.1"),
        "categories": [dict(zip(("id", "parentId", "name", "sortOrder"), row))
                       for row in CATEGORIES],
        "channels": [result[name] for name in sorted(result)],
    }
    validate(payload)
    return payload


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: python build_seed_catalog.py clubtivi.db output.json")
    catalog = build(sys.argv[1])
    Path(sys.argv[2]).write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"{len(catalog['channels'])} channels, "
          f"{sum(len(item['routes']) for item in catalog['channels'])} routes")
