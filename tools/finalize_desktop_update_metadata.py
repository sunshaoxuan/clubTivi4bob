"""Validate signed Mac packages and add Windows metadata/checksums for release."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "website"))
from mirror_releases import _inspect_update_archive, _verify_mac_signature, version_parts


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("version")
    args = parser.parse_args()
    version_parts(args.version)
    root = args.directory.resolve()
    metadata = root / "BobTV-update-metadata.json"
    payload = json.loads(metadata.read_text(encoding="utf-8"))
    if payload.get("schema") != 1 or payload.get("version") != args.version:
        raise ValueError("Metadata version mismatch")
    entries = {item["platform"]: item for item in payload["packages"]}
    if set(entries) - {"macos-x64", "macos-arm64", "windows-x64"}:
        raise ValueError("Unexpected platform")
    assets = []
    for platform in ("macos-x64", "macos-arm64", "windows-x64"):
        filename = f"BobTV-{args.version}-{platform}.zip"
        archive = root / filename
        _inspect_update_archive(archive, platform)
        checksum = digest(archive)
        size = archive.stat().st_size
        if platform.startswith("macos-"):
            entry = entries[platform]
            if (entry["filename"], entry["sha256"], entry["bytes"]) != (filename, checksum, size):
                raise ValueError("Signed Mac package metadata mismatch")
            _verify_mac_signature(archive, entry["signature"])
            image = root / f"BobTV-{args.version}-{platform}.dmg"
            with image.open("rb") as source:
                source.seek(-512, 2)
                if source.read(4) != b"koly":
                    raise ValueError("Invalid DMG trailer")
            assets.append(image)
        else:
            entries[platform] = {"platform": platform, "filename": filename,
                                 "sha256": checksum, "bytes": size}
        assets.append(archive)
    payload["packages"] = [entries[name] for name in ("windows-x64", "macos-x64", "macos-arm64")]
    metadata.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    assets.append(metadata)
    installer = root / f"BobTV-{args.version}-windows-x64-Setup.exe"
    if installer.exists():
        with installer.open("rb") as source:
            if source.read(2) != b"MZ":
                raise ValueError("Invalid Windows installer")
        assets.append(installer)
    (root / "SHA256SUMS.txt").write_text(
        "".join(f"{digest(path)}  {path.name}\n" for path in sorted(assets)), encoding="utf-8")
    print(f"Validated three platform updates and {len(assets)} release assets")


if __name__ == "__main__":
    main()
