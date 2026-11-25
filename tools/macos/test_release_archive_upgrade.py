"""Install a real release archive with the previous app's worker in an isolated copy.

Never launches media playback or changes the installed application. The worker
still performs its real signature, version, platform, backup and install checks.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def verify(previous_app, packages, platform):
    previous_app, packages = Path(previous_app).resolve(), Path(packages).resolve()
    metadata = json.loads((packages / 'BobTV-update-metadata.json').read_text())
    package = next(p for p in metadata['packages'] if p['platform'] == platform)
    archive = packages / package['filename']
    assert archive.stat().st_size == package['bytes']
    with archive.open('rb') as stream:
        assert hashlib.file_digest(stream, 'sha256').hexdigest() == package['sha256']
    old_assets = previous_app / 'Contents/Frameworks/App.framework/Resources/flutter_assets/assets/updater'
    # HOME is deliberately not overridden: the real worker restricts its state
    # to Application Support. A fresh random subdirectory isolates this run.
    base = Path.home() / 'Library/Application Support'
    with tempfile.TemporaryDirectory(prefix='BobTVArchiveUpgrade-', dir=base) as fixture:
        fixture = Path(fixture)
        app, state = fixture / 'BobTV.app', fixture / 'Update'
        state.mkdir()
        subprocess.run(['ditto', str(previous_app), str(app)], check=True)
        shutil.copy2(old_assets / 'update-signing-public.pem', state / 'update-signing-public.pem')
        shutil.copy2(archive, state / ('BobTV-' + metadata['version'].replace('+', '_') + '-macos.zip'))
        result = subprocess.run(['/bin/bash', str(old_assets / 'mac_worker.sh'), 'update',
            str(state), str(app), '99999999', metadata['version'],
            'https://bobtv.briconbric.com/updates/files/' + package['filename'],
            package['sha256'], str(package['bytes']), package['signature']], timeout=180)
        status = json.loads((state / 'status.json').read_text())
        if result.returncode or status['phase'] != 'installed':
            raise RuntimeError(json.dumps({'exitCode': result.returncode, 'status': status,
                'workerLog': (state / 'worker.log').read_text()[-5000:]}))
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleShortVersionString'] + '+' + str(info['CFBundleVersion']) == metadata['version']
        backup = Path((state / 'candidate.txt').read_text().splitlines()[1]) / 'BobTV.app'
        assert (backup / 'Contents/Info.plist').read_bytes() == (previous_app / 'Contents/Info.plist').read_bytes()
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        old_info = plistlib.loads((previous_app / 'Contents/Info.plist').read_bytes())
        return {'passed': True, 'previousVersion': old_info['CFBundleShortVersionString'] + '+' + str(old_info['CFBundleVersion']),
            'targetVersion': metadata['version'], 'platform': platform, 'phase': status['phase'],
            'previousBundleBackedUp': True, 'playbackLaunched': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('previous_app', type=Path)
    parser.add_argument('packages', type=Path)
    parser.add_argument('platform', choices=['macos-x64', 'macos-arm64'])
    args = parser.parse_args()
    print(json.dumps(verify(args.previous_app, args.packages, args.platform), indent=2))
