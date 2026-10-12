"""Normalize Windows archive paths and verify app-process CPU consistency."""
import argparse
import json
from pathlib import Path
import shutil
import struct
import zipfile


def normalize(source, output, architecture):
    source, output = Path(source), Path(output)
    if output.exists():
        raise ValueError('Preserve the existing output archive')
    seen = set()
    native = []
    expected = {'x64': 0x8664, 'arm64': 0xAA64}[architecture]
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(output, 'w') as target:
        for info in original.infolist():
            old = info.filename
            name = old.replace('\\', '/')
            if not name.startswith('BobTV/') or '..' in name.split('/') or ':' in name or name in seen:
                raise ValueError('Unsafe or duplicate package path: ' + name)
            seen.add(name)
            if name.count('/') == 1 and (name.endswith('.dll') or name.endswith('/BobTV.exe')):
                data = original.read(old)
                offset = struct.unpack_from('<I', data, 0x3c)[0]
                if data[:2] != b'MZ' or data[offset:offset+4] != b'PE\0\0':
                    raise ValueError('Invalid native file: ' + name)
                machine = struct.unpack_from('<H', data, offset+4)[0]
                if machine != expected:
                    raise ValueError('Wrong architecture: ' + name)
                native.append(name)
            if name == 'BobTV/data/app.so':
                data = original.read(old)[:20]
                if data[:4] != b'\x7fELF' or struct.unpack_from('<H', data, 18)[0] != {'x64': 62, 'arm64': 183}[architecture]:
                    raise ValueError('Wrong Dart AOT architecture')
            info.filename = name
            with original.open(old) as src, target.open(info, 'w') as dst:
                shutil.copyfileobj(src, dst, 1024 * 1024)
    if 'BobTV/BobTV.exe' not in seen or 'BobTV/data/app.so' not in seen:
        raise ValueError('Missing application files')
    with zipfile.ZipFile(output) as package:
        if package.testzip() is not None:
            raise ValueError('Package CRC failure')
    print(json.dumps({'architecture': architecture, 'nativeFiles': len(native),
                      'entries': len(seen), 'pathsNormalized': True, 'crcValid': True}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('architecture', choices=['x64', 'arm64'])
    args = parser.parse_args()
    normalize(args.source, args.output, args.architecture)
