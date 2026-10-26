#!/usr/bin/env python3
"""Fetch checksum-locked FFT runtimes for native application builds."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(platform, arch, output):
    lock = json.loads((ROOT / 'tools/native/runtime-lock.json').read_text())
    if digest(ROOT / 'tools/native/af_bobtv_spectrum.c') != lock['fftSourceSha256']:
        raise RuntimeError('The source and native FFT runtimes differ; rebuild the native artifacts')
    local = os.environ.get('BOBTV_AUDIO_RUNTIME_ARCHIVES')
    cache = ROOT / 'build/native-audio-runtime-cache'
    cache.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    entries = lock[platform]
    if platform == 'windows': entries = {arch: entries[arch]}
    for architecture, item in entries.items():
        path = Path(local) / item['filename'] if local else cache / item['filename']
        if not path.exists():
            if local: raise RuntimeError('Missing local runtime archive: ' + str(path))
            temporary = path.with_suffix(path.suffix + '.partial')
            urllib.request.urlretrieve(item['url'], temporary)
            if digest(temporary) != item['sha256']: raise RuntimeError('Runtime download checksum mismatch')
            temporary.replace(path)
        if digest(path) != item['sha256']: raise RuntimeError('Runtime checksum mismatch: ' + path.name)
        if platform == 'android':
            target = output / ('default-' + architecture + '.jar')
            with zipfile.ZipFile(path) as incoming, zipfile.ZipFile(target, 'w') as outgoing:
                for entry in incoming.infolist():
                    data = incoming.read(entry.filename)
                    if entry.filename == 'META-INF/bobtv-native-runtime.json':
                        entry.filename = f'META-INF/bobtv-native-runtime-{architecture}.json'
                    outgoing.writestr(entry, data)
        else:
            with zipfile.ZipFile(path) as archive:
                for member in archive.namelist():
                    if '\\' in member or Path(member).is_absolute() or '..' in Path(member).parts:
                        raise RuntimeError('Unsafe runtime archive member')
                archive.extractall(output)
    print(output.resolve())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['android', 'windows'])
    parser.add_argument('--arch', choices=['x64','arm64'])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.platform == 'windows' and not args.arch: parser.error('Windows runtime architecture is required')
    prepare(args.platform, args.arch, args.output.resolve())
