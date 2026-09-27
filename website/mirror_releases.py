"""Mirror published BobTV Windows assets before exposing them to visitors."""

import hashlib
import json
import os
import re
import urllib.request
from pathlib import Path

DATA = Path(os.environ.get("BOBTV_DATA_DIR", Path(__file__).resolve().parent / "data"))

API = "https://api.github.com/repos/sunshaoxuan/clubTivi4bob/releases?per_page=100"
NAME = re.compile(r"^BobTV-v[\w.-]+-windows-x64\.zip$")


def request(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "BobTV-release-mirror", "Accept": "application/vnd.github+json"}), timeout=90)


def mirror():
    with request(API) as response:
        releases = json.load(response)
    folder = DATA / "releases"
    folder.mkdir(parents=True, exist_ok=True)
    result = []
    for release in releases:
        for asset in release.get("assets", []):
            name = asset["name"]
            size = asset["size"]
            if not NAME.fullmatch(name) or size > 300 * 1024 * 1024:
                continue
            target = folder / name
            expected = asset.get("digest")
            checksum = None
            if target.exists() and target.stat().st_size == size:
                with target.open("rb") as mirrored:
                    checksum = hashlib.file_digest(mirrored, "sha256").hexdigest()
            if checksum is None or (expected and expected != f"sha256:{checksum}"):
                temp = folder / f".{name}.{os.getpid()}.tmp"
                try:
                    with request(asset["browser_download_url"]) as source, temp.open("wb") as output:
                        digest = hashlib.sha256()
                        total = 0
                        while chunk := source.read(1024 * 1024):
                            total += len(chunk)
                            if total > size:
                                raise ValueError(f"Asset grew unexpectedly: {name}")
                            digest.update(chunk)
                            output.write(chunk)
                    with temp.open("rb") as uploaded:
                        signature = uploaded.read(4)
                    if total != size or signature != b"PK\x03\x04":
                        raise ValueError(f"Asset invalid: {name}")
                    checksum = digest.hexdigest()
                    if expected and expected != f"sha256:{checksum}":
                        raise ValueError(f"Release checksum mismatch: {name}")
                    os.replace(temp, target)
                finally:
                    temp.unlink(missing_ok=True)
            result.append({"version": release["tag_name"], "date": release["published_at"][:10], "filename": name, "size": f"{size / 1048576:.1f} MB", "sha256": checksum})
    if not result:
        raise ValueError("No Windows release assets found; manifest unchanged")
    manifest = DATA / "releases.json"
    temp_manifest = DATA / f".releases.{os.getpid()}.tmp"
    temp_manifest.write_text(json.dumps({"releases": result}, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(temp_manifest, manifest)
    print(f"Published {len(result)} mirrored releases")


if __name__ == "__main__":
    mirror()
