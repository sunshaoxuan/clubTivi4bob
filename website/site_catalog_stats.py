"""Homepage figures derived from the published channel snapshot."""

import gzip
import json
import logging
import re
from collections import Counter
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from threading import Lock

import channel_catalog

FALLBACK = {
    "date": "2026-11-11", "countries": 174, "television": 8086,
    "radio": 579, "movies": 376, "news": 794, "entertainment": 531,
    "sports": 320, "documentaries": 158,
}
BROADCAST_ROOTS = {"国际", "中国", "其他"}
GENRES = {"广播": "radio", "电影": "movies", "新闻": "news",
          "娱乐": "entertainment", "体育": "sports", "纪录片": "documentaries"}
JST = timezone(timedelta(hours=9))
_snapshot_lock = Lock()
logger = logging.getLogger(__name__)


@lru_cache(maxsize=2)
def _snapshot_counts(path):
    with gzip.open(path, "rt", encoding="utf-8") as handle:
        data = json.load(handle)
    categories = {item["id"]: item for item in data["categories"]}

    @lru_cache(maxsize=None)
    def ancestry(category_id):
        names = []
        seen = set()
        while category_id:
            if category_id in seen or category_id not in categories:
                return ()
            seen.add(category_id)
            category = categories[category_id]
            names.append(category["name"])
            category_id = category["parentId"]
        return tuple(names)

    counts = Counter()
    countries = set()
    for channel in data["channels"]:
        code = channel.get("countryCode") or ""
        if code not in {"ZZ", "XX"} and re.fullmatch(r"[A-Z]{2}", code):
            countries.add(code)
        names = ancestry(channel["categoryId"])
        if not names or names[-1] not in BROADCAST_ROOTS:
            continue
        if "广播" in names:
            counts["radio"] += 1
            continue
        counts["television"] += 1
        counts.update(key for name, key in GENRES.items() if name in names)

    return {"countries": len(countries), "television": counts["television"],
            **{key: counts[key] for key in GENRES.values()}}


def catalog_stats():
    directory = channel_catalog.DATA / channel_catalog.DIRECTORY
    try:
        manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
        digest = manifest.get("sha256", "")
        if not channel_catalog.DIGEST.fullmatch(digest):
            return FALLBACK
        published = datetime.fromisoformat(manifest["generatedAt"].replace("Z", "+00:00"))
        snapshot = directory / "snapshots" / f"{digest}.json.gz"
        with _snapshot_lock:
            counts = _snapshot_counts(snapshot)
        return {**counts, "date": published.astimezone(JST).date().isoformat()}
    except FileNotFoundError:
        return FALLBACK
    except (OSError, EOFError, ValueError, KeyError, TypeError) as error:
        logger.warning("Could not read published homepage channel statistics: %s", error)
        return FALLBACK
