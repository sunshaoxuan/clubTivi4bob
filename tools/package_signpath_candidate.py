"""Package verified candidate bytes; never publish or reuse old update signatures."""
import argparse
import hashlib
import json
import zipfile
from pathlib import Path


def package(bundle: Path, setup: Path, output: Path, version: str, arch: str, mode: str):
    if not (bundle / 'BobTV.exe').is_file() or not setup.is_file():
        raise ValueError('Complete app and Setup are required')
    entries = sorted(bundle.rglob('*'))
    if bundle.is_symlink() or any(path.is_symlink() for path in entries):
        raise ValueError('Symlinks are not allowed in signing candidates')
    files = [path for path in entries if path.is_file()]
    for path in files:
        if path.is_symlink() or any(parent.is_symlink() for parent in path.parents):
            raise ValueError('Symlinks are not allowed in signing candidates')
        if (path.name.lower().startswith('procdump') or
                path.suffix.lower() in ('.p12', '.pfx') or
                path.suffix.lower() in ('.pem', '.key') and b'PRIVATE KEY' in path.read_bytes()):
            raise ValueError('Private keys and proprietary helpers must not be packaged')
    output.mkdir(parents=True, exist_ok=False)
    archive = output / f'BobTV-{version}-windows-{arch}-SIGNING-CANDIDATE.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as target:
        for path in files:
            target.write(path, 'BobTV/' + path.relative_to(bundle).as_posix())
    import shutil
    packaged_setup = output / setup.name
    shutil.copy2(setup, packaged_setup)
    payload = {'schema': 1, 'version': version, 'architecture': arch,
               'signingMode': mode, 'publicRelease': False,
               'requiresFreshPublisherUpdateMetadata': True, 'files': []}
    for path in (archive, packaged_setup):
        with path.open('rb') as source:
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        payload['files'].append({'filename': path.name, 'bytes': path.stat().st_size, 'sha256': digest})
    (output / 'candidate-manifest.json').write_text(json.dumps(payload, indent=2) + '\n')
    (output / 'SHA256SUMS.txt').write_text(''.join(f"{item['sha256']}  {item['filename']}\n" for item in payload['files']))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--setup', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--arch', choices=['x64', 'arm64'], required=True)
    parser.add_argument('--mode', choices=['unsigned', 'test-signing', 'release-signing'], required=True)
    args = parser.parse_args()
    package(args.bundle, args.setup, args.output, args.version, args.arch, args.mode)
