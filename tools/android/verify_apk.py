"""Verify the signed tablet artifacts before handing them to a tester."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import zipfile

PUBLISHER = '163f6e8d1474816420774d24ac3c08e7b5ac5d00759d65e0d2c1e517684bb714'
ABIS = {'arm': ('armeabi-v7a', 40), 'arm64': ('arm64-v8a', 183), 'x64': ('x86_64', 62)}


def load_alignments(data):
    if len(data) < 64 or data[:4] != b'\x7fELF' or data[5] != 1:
        raise ValueError('Invalid little-endian ELF')
    if data[4] == 2:
        offset = struct.unpack_from('<Q', data, 32)[0]
        size, count = struct.unpack_from('<HH', data, 54)
        alignment_offset, alignment_format, minimum = 48, '<Q', 56
    elif data[4] == 1:
        offset = struct.unpack_from('<I', data, 28)[0]
        size, count = struct.unpack_from('<HH', data, 42)
        alignment_offset, alignment_format, minimum = 28, '<I', 32
    else:
        raise ValueError('Invalid ELF class')
    if not 1 <= count <= 100 or size < minimum or offset + size * count > len(data):
        raise ValueError('Invalid ELF program headers')
    return [struct.unpack_from(alignment_format, data, offset + i * size + alignment_offset)[0]
            for i in range(count) if struct.unpack_from('<I', data, offset + i * size)[0] == 1]


def verify(path, tools):
    path = Path(path)
    architecture = re.search(r'-android-(arm|arm64|x64)\.apk$', path.name)
    if not architecture:
        raise ValueError('APK platform filename missing')
    architecture = architecture[1]
    abi, machine = ABIS[architecture]
    signature = subprocess.check_output([str(tools / 'apksigner'), 'verify', '--verbose',
                                        '--print-certs', str(path)], text=True)
    if f'certificate SHA-256 digest: {PUBLISHER}' not in signature:
        raise ValueError('APK publisher differs from BobTV release signer')
    subprocess.run([str(tools / 'zipalign'), '-c', '-P', '16', '4', str(path)], check=True)
    manifest = subprocess.check_output([str(tools / 'aapt'), 'dump', 'badging', str(path)], text=True)
    if "package: name='com.briconbric.bobtv'" not in manifest or "sdkVersion:'24'" not in manifest:
        raise ValueError('APK identity or minimum SDK changed')
    if "application-label:'BobTV'" not in manifest or f"native-code: '{abi}'" not in manifest:
        raise ValueError('APK label or ABI changed')
    tree = subprocess.check_output([str(tools / 'aapt'), 'dump', 'xmltree', str(path),
                                    'AndroidManifest.xml'], text=True)
    if re.search(r'android:debuggable[^\n]*0xffffffff', tree):
        raise ValueError('APK must not be debuggable')
    if not re.search(r'android:usesCleartextTraffic[^\n]*0x0', tree):
        raise ValueError('Public cleartext traffic must be disabled')
    libraries = []
    with zipfile.ZipFile(path) as package:
        for name in package.namelist():
            if re.search(r'(?i)(?:release\.p12|\.jks$|store-password|\.env(?:\.|$)|private.*\.pem)', name):
                raise ValueError('Private build material in APK')
            if name.startswith('lib/') and name.endswith('.so'):
                if not name.startswith(f'lib/{abi}/'):
                    raise ValueError('Unexpected extra native ABI')
                data = package.read(name)
                if struct.unpack_from('<H', data, 18)[0] != machine:
                    raise ValueError('Native machine mismatch')
                alignments = load_alignments(data)
                minimum = 4096 if architecture == 'arm' else 16384
                if not alignments or any(value < minimum for value in alignments):
                    raise ValueError(f'Native page alignment mismatch: {name}')
                libraries.append({'name': name, 'minimumLoadAlignment': min(alignments)})
    if not any(row['name'].endswith('/libmpv.so') for row in libraries):
        raise ValueError('Video decoder is missing')
    with path.open('rb') as source:
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
    return {'file': path.name, 'bytes': path.stat().st_size,
            'sha256': digest,
            'publisherSha256': PUBLISHER, 'abi': abi, 'minimumAndroidApi': 24,
            'signatureVerified': True, 'zipAligned16KiB': True,
            'privateBuildFilesAbsent': True, 'nativeLibraries': libraries}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('apk', type=Path, nargs='+')
    parser.add_argument('--build-tools', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps([verify(path, args.build_tools) for path in args.apk], indent=2))
