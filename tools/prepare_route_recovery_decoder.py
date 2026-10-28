"""Prepare a hash-checked FFmpeg executable in an isolated task directory.

No package installation, PATH change or system-library replacement is performed.
The wheel and its licence remain beside the executable for supply-chain audit.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tarfile
import tempfile
import urllib.request
from urllib.parse import urlsplit
import zipfile

VERSION = '0.6.0'
TAGS = {('Linux', 'x86_64'): 'manylinux2014_x86_64',
        ('Darwin', 'x86_64'): 'macosx_10_9_x86_64',
        ('Darwin', 'arm64'): 'macosx_11_0_arm64'}
INCOMPATIBLE_LINUX_SHA = 'e7e7fb30477f717e6f55f9180a70386c62677ef8a4d4d1a5d948f4098aa3eb99'
LINUX_ASSET = 'ffmpeg-n9.0-latest-linux64-lgpl-9.0.tar.xz'


def download(url, limit):
    allowed = ('pypi.org', 'files.pythonhosted.org', 'api.github.com', 'github.com', 'release-assets.githubusercontent.com')
    if urlsplit(url).scheme != 'https' or urlsplit(url).hostname not in allowed:
        raise ValueError('Unexpected package origin')
    request = urllib.request.Request(url, headers={'User-Agent': 'BobTV-Decoder-Preparation/1'})
    with urllib.request.urlopen(request, timeout=30) as response:
        if urlsplit(response.url).hostname not in allowed:
            raise ValueError('Unexpected package redirect')
        body = response.read(limit + 1)
    if len(body) > limit:
        raise ValueError('Package exceeds size limit')
    return body


def smoke_ts(executable):
    """A version string alone cannot validate a streaming-media decoder."""
    with tempfile.TemporaryDirectory(prefix='decoder-smoke-') as temporary:
        sample = Path(temporary) / 'sample.ts'
        subprocess.run([str(executable), '-nostdin', '-v', 'error', '-f', 'lavfi', '-i',
            'testsrc=size=160x90:rate=25', '-t', '0.4', '-threads', '1', '-c:v', 'mpeg2video',
            '-f', 'mpegts', str(sample)], capture_output=True, check=True, timeout=8)
        result = subprocess.run([str(executable), '-nostdin', '-v', 'error', '-threads', '1',
            '-filter_threads', '1', '-max_alloc', '33554432', '-protocol_whitelist', 'file,pipe',
            '-i', str(sample), '-map', '0:v:0', '-t', '1', '-progress', 'pipe:1', '-f', 'null', '-'],
            capture_output=True, timeout=8, check=True)
        if not any(int(value) > 0 for value in re.findall(rb'^frame=(\d+)\s*$', result.stdout, re.M)):
            raise ValueError('Decoder did not produce an actual TS video frame')


def prepare_linux(directory, executable):
    # FFmpeg's download page links to this builder. The former imageio Linux
    # 7.0.2 executable SIGSEGVs on MPEG-TS, even though its version probe succeeds.
    metadata = json.loads(download('https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest', 1024 * 1024))
    assets = [item for item in metadata['assets'] if item['name'] == LINUX_ASSET]
    if len(assets) != 1 or not re.fullmatch(r'sha256:[a-f0-9]{64}', assets[0].get('digest') or ''):
        raise ValueError('Unique hash-verified stable Linux decoder required')
    asset = assets[0]
    expected_url = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/' + LINUX_ASSET
    if asset['browser_download_url'] != expected_url:
        raise ValueError('Unexpected Linux decoder URL')
    cached = directory / LINUX_ASSET
    body = cached.read_bytes() if cached.is_file() and cached.stat().st_size <= 192 * 1024 * 1024 else b''
    if hashlib.sha256(body).hexdigest() != asset['digest'].split(':')[1]:
        body = download(expected_url, 192 * 1024 * 1024)
    if hashlib.sha256(body).hexdigest() != asset['digest'].split(':')[1]:
        raise ValueError('Linux decoder checksum mismatch')
    with tarfile.open(fileobj=io.BytesIO(body), mode='r:xz') as archive:
        binaries = [item for item in archive.getmembers() if item.isfile() and item.name.endswith('/bin/ffmpeg')]
        if len(binaries) != 1 or binaries[0].size > 256 * 1024 * 1024:
            raise ValueError('Unexpected Linux decoder executable')
        binary = archive.extractfile(binaries[0]).read()
        licences = [item for item in archive.getmembers() if item.isfile() and 'license' in item.name.lower()
                    and item.size < 128 * 1024]
        for index, item in enumerate(licences[:30]):
            (directory / f'LICENSE-linux-{index}.txt').write_bytes(archive.extractfile(item).read())
    (directory / LINUX_ASSET).write_bytes(body)
    temporary = directory / '.ffmpeg.linux.new'
    temporary.write_bytes(binary)
    temporary.chmod(0o755)
    smoke_ts(temporary)
    version = subprocess.run([str(temporary), '-version'], capture_output=True, timeout=8, check=True)
    if executable.exists():
        old = directory / 'ffmpeg-imageio-7.0.2-ts-incompatible'
        if old.exists():
            raise ValueError('Previous incompatible decoder already preserved')
        os.replace(executable, old)
        if (directory / 'receipt.json').exists():
            os.replace(directory / 'receipt.json', directory / 'receipt-imageio-ts-incompatible.json')
    os.replace(temporary, executable)
    receipt = {'package': 'BtbN/FFmpeg-Builds', 'asset': LINUX_ASSET,
        'archiveSha256': hashlib.sha256(body).hexdigest(), 'binarySha256': hashlib.sha256(binary).hexdigest(),
        'origin': expected_url, 'decoderVersion': version.stdout.decode().splitlines()[0],
        'silentTsSmokePassed': True, 'systemPackagesModified': False}
    (directory / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


def prepare(directory, replace_incompatible=False):
    directory = Path(directory).resolve()
    if directory.name != 'route-recovery':
        raise ValueError('Use a dedicated route-recovery directory')
    directory.mkdir(parents=True, exist_ok=True)
    executable = directory / 'ffmpeg'
    if executable.exists():
        known_bad = (platform.system(), platform.machine()) == ('Linux', 'x86_64') and \
            hashlib.sha256(executable.read_bytes()).hexdigest() == INCOMPATIBLE_LINUX_SHA
        if not replace_incompatible or not known_bad:
            raise ValueError('Existing decoder preserved; inspect its receipt before reusing')
    if (platform.system(), platform.machine()) == ('Linux', 'x86_64'):
        return prepare_linux(directory, executable)
    tag = TAGS[(platform.system(), platform.machine())]
    metadata = json.loads(download(f'https://pypi.org/pypi/imageio-ffmpeg/{VERSION}/json', 256 * 1024))
    wheels = [item for item in metadata['urls'] if item['filename'].endswith(tag + '.whl')]
    if len(wheels) != 1:
        raise ValueError('Unique platform wheel required')
    wheel = wheels[0]
    body = download(wheel['url'], 64 * 1024 * 1024)
    if hashlib.sha256(body).hexdigest() != wheel['digests']['sha256']:
        raise ValueError('Package checksum mismatch')
    with zipfile.ZipFile(io.BytesIO(body)) as archive:
        binaries = [item for item in archive.infolist() if item.filename.startswith('imageio_ffmpeg/binaries/ffmpeg-')]
        if len(binaries) != 1 or binaries[0].file_size > 160 * 1024 * 1024:
            raise ValueError('Unexpected wheel executable')
        binary = archive.read(binaries[0])
        licences = [item for item in archive.infolist() if 'license' in item.filename.lower() and item.file_size < 128 * 1024]
        for index, item in enumerate(licences):
            (directory / f'LICENSE-{index}.txt').write_bytes(archive.read(item))
    (directory / wheel['filename']).write_bytes(body)
    temporary = directory / '.ffmpeg.new'
    temporary.write_bytes(binary)
    temporary.chmod(0o755)
    smoke_ts(temporary)
    result = subprocess.run([str(temporary), '-version'], capture_output=True, timeout=8, check=True)
    os.replace(temporary, executable)
    receipt = {'package': 'imageio-ffmpeg', 'version': VERSION, 'wheel': wheel['filename'],
        'wheelSha256': hashlib.sha256(body).hexdigest(), 'binarySha256': hashlib.sha256(binary).hexdigest(),
        'origin': wheel['url'], 'decoderVersion': result.stdout.decode().splitlines()[0]}
    (directory / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True)
    parser.add_argument('--replace-incompatible', action='store_true')
    args = parser.parse_args()
    print(json.dumps(prepare(args.directory, args.replace_incompatible), indent=2))
