"""Split a freshly compiled Universal app and refresh its frozen sender policy."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

from refresh_frozen_helper import refresh

ROOT = Path(__file__).resolve().parents[2]
MACHO = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def prepare(universal, previous, output):
    universal, previous, output = map(Path, (universal, previous, output))
    if output.exists() or not (universal / 'Contents/MacOS/BobTV').is_file():
        raise ValueError('A new output directory and a fresh Universal app are required')
    output.mkdir(parents=True)
    report = []
    identity = os.environ.get("BOBTV_CODESIGN_IDENTITY", "-")
    signing = ["--sign", identity]
    if identity != "-":
        signing += ["--options", "runtime"]
    for architecture, cpu, deployment in [('x64', 'x86_64', '10.15'), ('arm64', 'arm64', '11.0')]:
        baseline = previous / architecture / 'BobTV.app/Contents/Resources'
        for component in ['AirPlay']:
            if not (baseline / component).is_dir():
                raise ValueError('Architecture-specific support bundle is missing: ' + component)
        app = output / architecture / 'BobTV.app'
        app.parent.mkdir()
        run('ditto', universal, app)
        resources = app / 'Contents/Resources'
        for component in ['AirPlay', 'Tools']:
            if (baseline / component).is_dir():
                run('ditto', baseline / component, resources / component)
        progress = resources / 'Updater/BobTVUpdateProgress.app'
        (progress / 'Contents/MacOS').mkdir(parents=True)
        shutil.copy2(ROOT / 'tools/macos/update_progress_info.plist', progress / 'Contents/Info.plist')
        run('xcrun', 'swiftc', '-target', f'{cpu}-apple-macos{deployment}', '-O',
            ROOT / 'tools/macos/update_progress.swift', '-o', progress / 'Contents/MacOS/BobTVUpdateProgress')
        binaries = []
        for file in app.rglob('*'):
            if file.is_symlink() or not file.is_file():
                continue
            with file.open('rb') as stream:
                magic = stream.read(4)
            if magic not in MACHO:
                continue
            archs = subprocess.check_output(['lipo', '-archs', str(file)], text=True).strip().split()
            if cpu not in archs:
                raise ValueError(f'Wrong architecture: {file}: {archs}')
            if len(archs) > 1:
                thin = file.with_name(file.name + '.bobtv-thin')
                run('lipo', file, '-thin', cpu, '-output', thin)
                thin.replace(file)
                file.chmod(0o755)
            binaries.append(file)
        refresh(resources / 'AirPlay/bobtv-airplay/bobtv-airplay', ROOT / 'tools/airplay')
        for binary in binaries:
            run('codesign', '--force', *signing, binary)
        run('codesign', '--force', '--deep', *signing, progress)
        run('codesign', '--force', '--deep', '--entitlements', ROOT / 'macos/Runner/Release.entitlements', *signing, app)
        run('codesign', '--verify', '--deep', '--strict', app)
        report.append({'architecture': architecture, 'nativeFiles': len(binaries),
                       'app': str(app), 'freshUniversalRunner': True,
                       'senderSourceRefreshed': True, 'codeSignatureVerified': True})
    (output / 'variant-validation.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('universal', type=Path)
    parser.add_argument('previous_support', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    prepare(args.universal, args.previous_support, args.output)
