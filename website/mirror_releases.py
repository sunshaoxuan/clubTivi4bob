"""Mirror published BobTV Windows assets before exposing them to visitors."""

import hashlib
import base64
import json
import os
import posixpath
import re
import subprocess
import tempfile
import urllib.request
import zipfile
import struct
from pathlib import Path

DATA = Path(os.environ.get("BOBTV_DATA_DIR", Path(__file__).resolve().parent / "data"))

API = "https://api.github.com/repos/sunshaoxuan/clubTivi4bob/releases?per_page=100"
NAME = re.compile(r"^BobTV-[A-Za-z0-9.+_-]+-(windows-(x64|arm64)(?:\.zip|-Setup\.exe)|macos-(x64|arm64)\.dmg|android-(arm|arm64|x64)\.apk)$")
UPDATE_METADATA = "BobTV-update-metadata.json"
UPDATE_VERSION = re.compile(r"^\d+\.\d+\.\d+\+\d+$")
UPDATE_NAME = re.compile(r"^BobTV-[A-Za-z0-9.+_-]+\.(zip|apk)$")
UPDATE_PLATFORMS = {"windows-x64", "windows-arm64", "macos-x64", "macos-arm64", "android-arm", "android-arm64", "android-x64"}
MAX_UPDATE_BYTES = 2_000_000_000
UPDATE_PUBLIC_KEY = Path(__file__).resolve().parent / "update-signing-public.pem"


def _verify_publisher_signature(archive, encoded):
    if not isinstance(encoded, str) or not re.fullmatch(r"[A-Za-z0-9+/]{80,120}={0,2}", encoded):
        raise ValueError("Update signature is missing or invalid")
    try:
        signature = base64.b64decode(encoded, validate=True)
    except ValueError as exc:
        raise ValueError("Invalid Mac update signature encoding") from exc
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "signature.der"
        path.write_bytes(signature)
        result = subprocess.run(["openssl", "dgst", "-sha256", "-verify",
                                 str(UPDATE_PUBLIC_KEY), "-signature", str(path),
                                 str(archive)], capture_output=True, check=False)
    if result.returncode != 0:
        raise ValueError("Update publisher signature mismatch")


_verify_mac_signature = _verify_publisher_signature


def version_parts(version):
    if not isinstance(version, str) or not UPDATE_VERSION.fullmatch(version):
        raise ValueError("Invalid update version")
    return tuple(map(int, re.split(r"[.+]", version)))


def _download_verified(asset, target, expected_hash=None):
    size = asset["size"]
    if not isinstance(size, int) or not 1_000_000 <= size <= MAX_UPDATE_BYTES:
        raise ValueError("Invalid update asset size")
    github_hash = asset.get("digest")
    if github_hash and not re.fullmatch(r"sha256:[a-f0-9]{64}", github_hash):
        raise ValueError("Invalid GitHub asset digest")
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_file() and target.stat().st_size == size:
        current_digest = hashlib.sha256()
        with target.open("rb") as cached:
            while chunk := cached.read(1024 * 1024):
                current_digest.update(chunk)
        current_hash = current_digest.hexdigest()
        if current_hash == expected_hash and (not github_hash or github_hash == f"sha256:{current_hash}"):
            return
    temporary = target.with_name(f".{target.name}.{os.getpid()}.tmp")
    try:
        digest = hashlib.sha256()
        total = 0
        with request(asset["browser_download_url"]) as source, temporary.open("wb") as output:
            while chunk := source.read(1024 * 1024):
                total += len(chunk)
                if total > size:
                    raise ValueError("Update asset grew unexpectedly")
                digest.update(chunk)
                output.write(chunk)
        with temporary.open("rb") as downloaded:
            signature = downloaded.read(4)
        if total != size or (signature != b"PK\x03\x04" if not target.name.endswith('.exe') else signature[:2] != b'MZ'):
            raise ValueError("Invalid update archive")
        actual_hash = digest.hexdigest()
        if actual_hash != expected_hash or (github_hash and github_hash != f"sha256:{actual_hash}"):
            raise ValueError("Update checksum mismatch")
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def _inspect_update_archive(path, platform):
    windows = platform.startswith('windows-')
    android = platform.startswith('android-')
    abi = {'android-arm': 'armeabi-v7a', 'android-arm64': 'arm64-v8a', 'android-x64': 'x86_64'}.get(platform)
    root = '' if android else "BobTV/" if windows else "BobTV.app/"
    required = ({"BobTV/BobTV.exe", "BobTV/data/app.so"}
                if windows else
                {'AndroidManifest.xml', 'classes.dex', f'lib/{abi}/libflutter.so'} if android else
                {"BobTV.app/Contents/MacOS/BobTV", "BobTV.app/Contents/Info.plist"})
    try:
        with zipfile.ZipFile(path) as package:
            entries = package.infolist()
            if not 1 <= len(entries) <= 5000 or sum(item.file_size for item in entries) > MAX_UPDATE_BYTES:
                raise ValueError("Invalid update archive size")
            names = set()
            for item in entries:
                name = item.filename
                parts = name.split("/")
                if (not name.startswith(root) or len(name) > 300 or
                    "\\" in name or ":" in name or ".." in parts or
                    "" in parts[:-1]):
                    raise ValueError("Unsafe update archive entry")
                if (item.external_attr >> 16) & 0o170000 == 0o120000:
                    if item.file_size > 4096:
                        raise ValueError("Unsafe update archive symlink")
                    target = package.read(item).decode("utf-8")
                    resolved = posixpath.normpath(posixpath.join(
                        posixpath.dirname(name), target))
                    if (not target or target.startswith("/") or
                        "\\" in target or "\x00" in target or
                        resolved != root[:-1] and not resolved.startswith(root)):
                        raise ValueError("Unsafe update archive symlink")
                names.add(name)
            if not required <= names:
                raise ValueError("Update archive is missing application files")
            if android:
                for name in names:
                    if name.startswith(f'lib/{abi}/') and name.endswith('.so'):
                        with package.open(name) as binary:
                            header = binary.read(20)
                        if len(header) != 20 or header[:4] != b'\x7fELF' or header[5] != 1 or struct.unpack_from('<H', header, 18)[0] != {'android-arm':40,'android-arm64':183,'android-x64':62}[platform]:
                            raise ValueError('APK native library architecture mismatch')
            if platform == 'windows-arm64':
                with package.open('BobTV/data/app.so') as binary:
                    header = binary.read(20)
                if len(header) != 20 or header[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', header, 18)[0] != 183:
                    raise ValueError('Windows ARM64 archive contains wrong-architecture Dart AOT')
                for name in names:
                    if name == 'BobTV/BobTV.exe' or (name.startswith('BobTV/') and name.count('/') == 1 and name.endswith('.dll')):
                        with package.open(name) as binary:
                            header = binary.read(1048582)
                        offset = struct.unpack_from('<I', header, 60)[0] if len(header) >= 64 else 0
                        if header[:2] != b'MZ' or not 64 <= offset <= 1048576 or offset + 6 > len(header) or header[offset:offset+4] != b'PE\0\0' or struct.unpack_from('<H', header, offset+4)[0] != 0xaa64:
                            raise ValueError('Windows ARM64 archive contains wrong-architecture native binary')
    except zipfile.BadZipFile as exc:
        raise ValueError("Invalid update ZIP") from exc


def _mirror_updates(release, selected):
    assets = {asset["name"]: asset for asset in release.get("assets", [])}
    metadata_asset = assets.get(UPDATE_METADATA)
    if metadata_asset is None or release.get("draft") or release.get("prerelease"):
        return
    if not isinstance(metadata_asset.get("size"), int) or metadata_asset["size"] > 65536:
        raise ValueError("Update metadata too large")
    with request(metadata_asset["browser_download_url"]) as response:
        raw = response.read(65537)
    if len(raw) != metadata_asset["size"] or len(raw) > 65536:
        raise ValueError("Update metadata size mismatch")
    if metadata_asset.get("digest") and metadata_asset["digest"] != f"sha256:{hashlib.sha256(raw).hexdigest()}":
        raise ValueError("Update metadata checksum mismatch")
    payload = json.loads(raw)
    if not isinstance(payload, dict) or set(payload) != {"schema", "version", "packages"} or payload["schema"] != 1:
        raise ValueError("Invalid update metadata")
    version = payload["version"]
    version_parts(version)
    packages = payload["packages"]
    if not isinstance(packages, list) or not packages:
        raise ValueError("Update metadata has no packages")
    seen = set()
    for package in packages:
        if not isinstance(package, dict) or not {"platform", "filename", "sha256", "bytes"} <= set(package) or set(package) - {"platform", "filename", "sha256", "bytes", "signature", "installer"}:
            raise ValueError("Invalid update package entry")
        platform = package["platform"]
        filename = package["filename"]
        checksum = package["sha256"]
        if platform not in UPDATE_PLATFORMS or platform in seen or not isinstance(filename, str) or not UPDATE_NAME.fullmatch(filename) or platform not in filename:
            raise ValueError("Invalid update platform or filename")
        if filename.endswith('.apk') != platform.startswith('android-'):
            raise ValueError('Update package type does not match platform')
        extension = 'apk' if platform.startswith('android-') else 'zip'
        if filename != f'BobTV-{version}-{platform}.{extension}':
            raise ValueError('Update filename must match exact version and platform')
        seen.add(platform)
        if not isinstance(checksum, str) or not re.fullmatch(r"[a-f0-9]{64}", checksum):
            raise ValueError("Invalid update checksum")
        asset = assets.get(filename)
        if asset is None or type(package["bytes"]) is not int or asset["size"] != package["bytes"]:
            raise ValueError("Update archive is missing or changed")
        target = DATA / "updates" / "files" / filename
        _download_verified(asset, target, checksum)
        _inspect_update_archive(target, platform)
        if platform.startswith("macos-"):
            _verify_mac_signature(target, package.get("signature"))
        elif "signature" in package:
            raise ValueError("Unexpected non-Mac update signature")
        installer_entry = None
        if 'installer' in package:
            item = package['installer']
            if not platform.startswith('windows-') or not isinstance(item,dict) or set(item) != {'filename','sha256','bytes','signature'}:
                raise ValueError('Invalid installer metadata')
            installer_name = f'BobTV-{version}-{platform}-Setup.exe'
            installer_asset = assets.get(installer_name)
            if item['filename'] != installer_name or installer_asset is None or type(item['bytes']) is not int or item['bytes'] != installer_asset['size'] or not isinstance(item['sha256'],str) or not re.fullmatch('[a-f0-9]{64}', item['sha256']):
                raise ValueError('Installer missing or changed')
            installer_path = DATA / 'updates/files' / installer_name
            _download_verified(installer_asset, installer_path, item['sha256'])
            _verify_publisher_signature(installer_path, item['signature'])
            installer_entry = {'archive':f'https://bobtv.briconbric.com/updates/files/{installer_name}',
                               'sha256':item['sha256'],'bytes':item['bytes'],'signature':item['signature']}
        historical = {'schema':1,'version':version,
            'archive':f'https://bobtv.briconbric.com/updates/files/{filename}',
            'sha256':checksum,'bytes':package['bytes'],'publishedAt':release['published_at']}
        if platform.startswith('macos-'): historical['signature'] = package['signature']
        if installer_entry: historical['installer'] = installer_entry
        history_path = DATA / 'updates' / platform / 'versions' / f'{version}.json'
        history_path.parent.mkdir(parents=True,exist_ok=True)
        history_tmp = history_path.with_name(f'.{version}.{os.getpid()}.tmp')
        history_tmp.write_text(json.dumps(historical,separators=(',',':')),encoding='utf-8')
        os.replace(history_tmp,history_path)
        current = selected.get(platform)
        if current is None or version_parts(version) > version_parts(current["version"]):
            selected[platform] = {
                "schema": 1, "version": version,
                "archive": f"https://bobtv.briconbric.com/updates/files/{filename}",
                "sha256": checksum, "bytes": package["bytes"],
                "publishedAt": release["published_at"],
            }
            if platform.startswith("macos-"):
                selected[platform]["signature"] = package["signature"]
            if installer_entry: selected[platform]['installer'] = installer_entry


def request(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "BobTV-release-mirror", "Accept": "application/vnd.github+json"}), timeout=90)


def mirror():
    with request(API) as response:
        releases = json.load(response)
    folder = DATA / "releases"
    folder.mkdir(parents=True, exist_ok=True)
    result = []
    updates = {}
    for release in releases:
        _mirror_updates(release, updates)
        for asset in release.get("assets", []):
            name = asset["name"]
            size = asset["size"]
            if (not NAME.fullmatch(name) or size > 500 * 1024 * 1024 or
                    name.endswith(".dmg") and size < 512):
                continue
            target = folder / name
            expected = asset.get("digest")
            checksum = None
            if target.exists() and target.stat().st_size == size:
                with target.open("rb") as mirrored:
                    digest = hashlib.sha256()
                    while chunk := mirrored.read(1024 * 1024):
                        digest.update(chunk)
                    checksum = digest.hexdigest()
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
                        if name.endswith(".dmg"):
                            uploaded.seek(-512, os.SEEK_END)
                            signature = uploaded.read(4)
                            expected_signature = b"koly"
                        elif name.endswith(".exe"):
                            header = uploaded.read(64)
                            if len(header) != 64 or header[:2] != b"MZ":
                                raise ValueError(f"Installer header invalid: {name}")
                            pe_offset = int.from_bytes(header[60:64], "little")
                            if not 64 <= pe_offset <= size - 4:
                                raise ValueError(f"Installer PE offset invalid: {name}")
                            uploaded.seek(pe_offset)
                            signature = uploaded.read(4)
                            expected_signature = b"PE\x00\x00"
                        else:
                            signature = uploaded.read(4)
                            expected_signature = b"PK\x03\x04"
                    if total != size or signature != expected_signature:
                        raise ValueError(f"Asset invalid: {name}")
                    checksum = digest.hexdigest()
                    if expected and expected != f"sha256:{checksum}":
                        raise ValueError(f"Release checksum mismatch: {name}")
                    os.replace(temp, target)
                finally:
                    temp.unlink(missing_ok=True)
            platform = ("Android ARM64" if name.endswith('android-arm64.apk') else
                        "Android ARM32" if name.endswith('android-arm.apk') else
                        "Android x64" if name.endswith('android-x64.apk') else
                        "Windows ARM64" if name.endswith(('windows-arm64.zip','windows-arm64-Setup.exe')) else
                        "Windows x64" if name.endswith(("windows-x64.zip", "windows-x64-Setup.exe")) else
                        "macOS Intel" if name.endswith("macos-x64.dmg") else
                        "macOS Apple Silicon")
            result.append({"version": release["tag_name"], "date": release["published_at"][:10],
                           "platform": platform, "filename": name,
                           "size": f"{size / 1048576:.1f} MB", "sha256": checksum})
    if not result and not updates:
        raise ValueError("No eligible release assets found; manifest unchanged")
    if result:
        manifest = DATA / "releases.json"
        temp_manifest = DATA / f".releases.{os.getpid()}.tmp"
        temp_manifest.write_text(json.dumps({"releases": result}, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(temp_manifest, manifest)
    if updates:
        approved_path = DATA / "updates" / "approved.json"
        if approved_path.is_file():
            approved = json.loads(approved_path.read_text(encoding="utf-8"))
            if not isinstance(approved, dict):
                raise ValueError("Invalid approved update registry")
        else:
            approved = {}
        historical_entries = list(updates.values())
        for platform in UPDATE_PLATFORMS:
            for history in (DATA/'updates'/platform/'versions').glob('*.json'):
                historical_entries.append(json.loads(history.read_text(encoding='utf-8')))
        for entry in historical_entries:
            filename = entry["archive"].rsplit("/", 1)[-1]
            approved[filename] = entry["sha256"]
            if entry.get('installer'):
                approved[entry['installer']['archive'].rsplit('/',1)[-1]] = entry['installer']['sha256']
        temporary = approved_path.with_name(f".approved.{os.getpid()}.tmp")
        temporary.write_text(json.dumps(approved, separators=(",", ":")), encoding="utf-8")
        os.replace(temporary, approved_path)
    for platform, entry in updates.items():
        path = DATA / "updates" / platform / "latest.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        previous = None
        if path.is_file():
            try:
                previous = json.loads(path.read_text(encoding="utf-8"))
            except ValueError:
                pass
        if previous and (version_parts(previous["version"]) > version_parts(entry["version"]) or previous == entry):
            continue
        temporary = path.with_name(f".latest.{os.getpid()}.tmp")
        temporary.write_text(json.dumps(entry, separators=(",", ":")), encoding="utf-8")
        os.replace(temporary, path)
    print(f"Published {len(result)} mirrored releases")


if __name__ == "__main__":
    mirror()
