"""Expose semantic-version filenames while preserving native updater identity."""
import argparse
import json
from pathlib import Path


def canonicalize(root, version):
    base, build = version.split('+')
    if not build.isdigit():
        raise ValueError('Invalid native build')
    metadata = root / 'BobTV-update-metadata.json'
    payload = json.loads(metadata.read_text())
    if payload['version'] != version:
        raise ValueError('Metadata mismatch')
    for source in root.glob(f'BobTV-{version}-*'):
        target = source.with_name(source.name.replace(version, base, 1))
        if target.exists():
            raise FileExistsError(target)
        source.rename(target)
    for entry in payload['packages']:
        entry['filename'] = entry['filename'].replace(version, base, 1)
    payload['displayVersion'] = base
    metadata.write_text(json.dumps(payload, separators=(',', ':')))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('version')
    args = parser.parse_args()
    canonicalize(args.directory, args.version)
