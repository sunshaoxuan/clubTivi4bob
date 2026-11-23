"""Validate platform packages and finalize mirror metadata/checksums."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import base64
import subprocess
import tempfile
import os

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "website"))
from updater_bundle import build as build_updater_bundle
from mirror_releases import _inspect_update_archive, _verify_mac_signature, version_parts, UPDATE_PLATFORMS

PLATFORMS = ('windows-x64', 'windows-arm64', 'macos-x64', 'macos-arm64',
             'android-arm64', 'android-arm', 'android-x64')
DESKTOP_PLATFORMS = PLATFORMS[:4]


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
    parser.add_argument('--signing-key', type=Path,
                        default=os.environ.get('BOBTV_UPDATE_SIGNING_KEY'))
    parser.add_argument("--platforms", nargs="+", choices=PLATFORMS,
                        default=list(PLATFORMS))
    parser.add_argument("--staging", action="store_true", help="Create platform build staging metadata; never a complete official release")
    parser.add_argument('--desktop-only', action='store_true',
                        help='Explicit desktop-only publication; preserve mobile releases and feeds')
    args = parser.parse_args()
    if args.desktop_only:
        if set(args.platforms) not in (set(PLATFORMS), set(DESKTOP_PLATFORMS)):
            raise ValueError('Desktop publication requires all four desktop platforms')
        args.platforms = list(DESKTOP_PLATFORMS)
    if set(args.platforms) != set(PLATFORMS) and not (args.staging or args.desktop_only):
        raise ValueError("Official releases require all seven platforms at the same version; use --staging only for intermediate platform builds")
    version_parts(args.version)
    root = args.directory.resolve()
    metadata = root / "BobTV-update-metadata.json"
    payload = (json.loads(metadata.read_text(encoding="utf-8")) if metadata.exists()
               else {"schema": 1, "version": args.version, "packages": []})
    if payload.get("schema") != 1 or payload.get("version") != args.version:
        raise ValueError("Metadata version mismatch")
    display_version = payload.get('displayVersion', args.version)
    if 'displayVersion' in payload and display_version != args.version.split('+')[0]:
        raise ValueError('Public version must match native semantic version')
    entries = {item["platform"]: item for item in payload["packages"]}
    if set(entries) - UPDATE_PLATFORMS:
        raise ValueError("Unexpected platform")
    assets = []
    selected = set(args.platforms)
    if set(entries) - selected:
        raise ValueError("Metadata contains a platform excluded from this publication")
    for platform in (name for name in PLATFORMS if name in selected):
        extension = 'apk' if platform.startswith('android-') else 'zip'
        filename = f"BobTV-{display_version}-{platform}.{extension}"
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
            image = root / f"BobTV-{display_version}-{platform}.dmg"
            with image.open("rb") as source:
                source.seek(-512, 2)
                if source.read(4) != b"koly":
                    raise ValueError("Invalid DMG trailer")
            assets.append(image)
        else:
            entries[platform] = {"platform": platform, "filename": filename,
                                 "sha256": checksum, "bytes": size}
            installer = root / f'BobTV-{display_version}-{platform}-Setup.exe'
            if platform.startswith('windows-') and installer.exists():
                if not args.signing_key:
                    raise ValueError('Windows automatic Setup updates require the BobTV publisher signing key')
                with installer.open('rb') as source:
                    header=source.read(64)
                    offset=int.from_bytes(header[60:64],'little') if len(header)==64 else 0
                    if header[:2] != b'MZ' or not 64 <= offset <= installer.stat().st_size-4:
                        raise ValueError('Invalid Windows installer')
                    source.seek(offset)
                    if source.read(4) != b'PE\x00\x00':
                        raise ValueError('Invalid Windows installer PE signature')
                with tempfile.TemporaryDirectory() as folder:
                    signature_path=Path(folder)/'signature.der'
                    subprocess.run(['openssl','dgst','-sha256','-sign',str(args.signing_key),
                                    '-out',str(signature_path),str(installer)],check=True,capture_output=True)
                    signature=base64.b64encode(signature_path.read_bytes()).decode('ascii')
                _verify_mac_signature(installer,signature)
                entries[platform]['installer']={'filename':installer.name,'sha256':digest(installer),
                                               'bytes':installer.stat().st_size,'signature':signature}
        if platform.startswith('windows-'):
            if not args.signing_key:
                raise ValueError('Windows updater components require the publisher signing key')
            component = root / f'BobTV-{args.version.split("+")[0]}-{platform}-Updater.zip'
            build_updater_bundle(Path(__file__).resolve().parents[1]/'assets/updater', component, args.version)
            with tempfile.TemporaryDirectory() as folder:
                signature_path = Path(folder)/'updater.der'
                subprocess.run(['openssl','dgst','-sha256','-sign',str(args.signing_key),
                    '-out',str(signature_path),str(component)],check=True,capture_output=True)
                signature = base64.b64encode(signature_path.read_bytes()).decode('ascii')
            _verify_mac_signature(component, signature)
            entries[platform]['updater'] = {'filename':component.name, 'sha256':digest(component),
                'bytes':component.stat().st_size, 'signature':signature}
            assets.append(component)
        assets.append(archive)
    payload["packages"] = [entries[name] for name in PLATFORMS if name in selected]
    metadata.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    assets.append(metadata)
    for platform in ('windows-x64', 'windows-arm64'):
        installer = root / f"BobTV-{display_version}-{platform}-Setup.exe"
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
