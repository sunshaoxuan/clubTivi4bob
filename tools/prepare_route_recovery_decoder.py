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
import subprocess
import urllib.request
from urllib.parse import urlsplit
import zipfile

VERSION = '0.6.0'
TAGS = {('Linux', 'x86_64'): 'manylinux2014_x86_64',
        ('Darwin', 'x86_64'): 'macosx_10_9_x86_64',
        ('Darwin', 'arm64'): 'macosx_11_0_arm64'}


def download(url, limit):
    if urlsplit(url).scheme != 'https' or urlsplit(url).hostname not in ('pypi.org', 'files.pythonhosted.org'):
        raise ValueError('Unexpected package origin')
    with urllib.request.urlopen(url, timeout=30) as response:
        if urlsplit(response.url).hostname not in ('pypi.org', 'files.pythonhosted.org'):
            raise ValueError('Unexpected package redirect')
        body = response.read(limit + 1)
    if len(body) > limit:
        raise ValueError('Package exceeds size limit')
    return body


def prepare(directory):
    directory = Path(directory).resolve()
    if directory.name != 'route-recovery':
        raise ValueError('Use a dedicated route-recovery directory')
    directory.mkdir(parents=True, exist_ok=True)
    executable = directory / 'ffmpeg'
    if executable.exists():
        raise ValueError('Existing decoder preserved; inspect its receipt before reusing')
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
    print(json.dumps(prepare(parser.parse_args().directory), indent=2))
