"""Validate platform packages and finalize mirror metadata/checksums."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "website"))
from mirror_releases import _inspect_update_archive, _verify_mac_signature, version_parts, UPDATE_PLATFORMS

PLATFORMS = ('windows-x64', 'windows-arm64', 'macos-x64', 'macos-arm64',
             'android-arm64', 'android-arm', 'android-x64')


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
    parser.add_argument("--platforms", nargs="+", choices=PLATFORMS,
                        default=["windows-x64", "macos-x64", "macos-arm64"])
    args = parser.parse_args()
    version_parts(args.version)
    root = args.directory.resolve()
    metadata = root / "BobTV-update-metadata.json"
    payload = (json.loads(metadata.read_text(encoding="utf-8")) if metadata.exists()
               else {"schema": 1, "version": args.version, "packages": []})
    if payload.get("schema") != 1 or payload.get("version") != args.version:
        raise ValueError("Metadata version mismatch")
    entries = {item["platform"]: item for item in payload["packages"]}
    if set(entries) - UPDATE_PLATFORMS:
        raise ValueError("Unexpected platform")
    assets = []
    selected = set(args.platforms)
    if set(entries) - selected:
        raise ValueError("Metadata contains a platform excluded from this publication")
    for platform in (name for name in PLATFORMS if name in selected):
        extension = 'apk' if platform.startswith('android-') else 'zip'
        filename = f"BobTV-{args.version}-{platform}.{extension}"
        archive = root / filename
        _inspect_update_archive(archive, platform)
        checksum = digest(archive)
        size = archive.stat().st_size
        if platform.startswith("macos-"):
            if platform not in entries:
                raise ValueError("Signed Mac metadata is required before finalization")
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
    payload["packages"] = [entries[name] for name in PLATFORMS if name in selected]
    metadata.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    assets.append(metadata)
    for platform in ('windows-x64', 'windows-arm64'):
        installer = root / f"BobTV-{args.version}-{platform}-Setup.exe"
        if platform in selected and installer.exists():
            with installer.open("rb") as source:
                if source.read(2) != b"MZ":
                    raise ValueError("Invalid Windows installer")
            assets.append(installer)
    (root / "SHA256SUMS.txt").write_text(
        "".join(f"{digest(path)}  {path.name}\n" for path in sorted(assets)), encoding="utf-8")
    print(f"Validated {len(selected)} platform updates and {len(assets)} release assets")


if __name__ == "__main__":
    main()
