"""Gate an official release on seven matching platform versions and real APK identity."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'website'))
from mirror_releases import _inspect_update_archive, _verify_publisher_signature, version_parts
from android.verify_apk import verify as verify_apk
from finalize_desktop_update_metadata import PLATFORMS


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_matrix(metadata, version):
    version_parts(version)
    if metadata.get('schema') != 1 or metadata.get('version') != version:
        raise ValueError('Release metadata version mismatch')
    packages = metadata.get('packages', [])
    if len(packages) != len(PLATFORMS) or {p.get('platform') for p in packages} != set(PLATFORMS):
        raise ValueError('Official release requires exactly all seven platforms')
    for package in packages:
        ext = 'apk' if package['platform'].startswith('android-') else 'zip'
        if package.get('filename') != f"BobTV-{version}-{package['platform']}.{ext}":
            raise ValueError('Platform version/build mismatch: ' + package['platform'])
    return packages


def verify(directory, version, build_tools):
    directory = Path(directory)
    metadata = json.loads((directory / 'BobTV-update-metadata.json').read_text())
    packages = validate_matrix(metadata, version)
    source_version = re.search(r'^version:\s*(\S+)', (ROOT/'pubspec.yaml').read_text(), re.M)[1]
    if source_version != version or version not in (ROOT/'lib/core/app_version.dart').read_text():
        raise ValueError('Source version differs from official release')
    assets = {'BobTV-update-metadata.json'}
    android = []
    base, build = version.split('+')
    for package in packages:
        path = directory/package['filename']
        if path.stat().st_size != package['bytes'] or digest(path) != package['sha256']:
            raise ValueError('Package size/hash mismatch: ' + path.name)
        _inspect_update_archive(path, package['platform'])
        assets.add(path.name)
        if package['platform'].startswith('android-'):
            details = verify_apk(path, Path(build_tools))
            manifest = subprocess.check_output([str(Path(build_tools)/'aapt'), 'dump', 'badging', str(path)], text=True)
            offset = {'android-arm':1000, 'android-arm64':2000, 'android-x64':4000}[package['platform']]
            if f"versionName='{base}'" not in manifest or f"versionCode='{offset+int(build)}'" not in manifest:
                raise ValueError('Embedded Android version/build differs: ' + path.name)
            details.update(versionName=base, versionCode=offset+int(build), baseBuildNumber=int(build))
            android.append(details)
        elif package['platform'].startswith('macos-'):
            _verify_publisher_signature(path, package['signature'])
            with zipfile.ZipFile(path) as archive:
                info=plistlib.loads(archive.read('BobTV.app/Contents/Info.plist'))
            if info['CFBundleShortVersionString']+'+'+str(info['CFBundleVersion']) != version:
                raise ValueError('Embedded Mac version/build differs')
            assets.add(path.name.removesuffix('.zip')+'.dmg')
        else:
            installer=package['installer'];target=directory/installer['filename']
            if target.stat().st_size != installer['bytes'] or digest(target) != installer['sha256']:
                raise ValueError('Windows Setup hash mismatch')
            _verify_publisher_signature(target, installer['signature'])
            assets.add(target.name)
    checksums={}
    for line in (directory/'SHA256SUMS.txt').read_text().splitlines():
        sha,name=line.split('  ',1)
        if name in checksums:raise ValueError('Duplicate checksum entry')
        checksums[name]=sha
    if set(checksums) != assets or len(assets) != 12:
        raise ValueError('Expected checksums for twelve release files')
    for name,sha in checksums.items():
        if digest(directory/name) != sha:raise ValueError('Checksum mismatch: '+name)
    if {p.name for p in directory.iterdir() if p.is_file()} != assets | {'SHA256SUMS.txt'}:
        raise ValueError('Official release must contain exactly thirteen assets')
    return {'passed':True,'version':version,'platforms':list(PLATFORMS),'assets':13,'android':android}


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('directory',type=Path)
    parser.add_argument('version')
    parser.add_argument('--android-build-tools',type=Path,required=True)
    args=parser.parse_args()
    print(json.dumps(verify(args.directory,args.version,args.android_build_tools),indent=2))
