"""Online SQLite backups and the exact currently published immutable catalog."""
import hashlib
import json
import os
import re
import shutil
import sqlite3
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def backup(directory):
    directory = Path(directory)
    destination = directory / 'backups'
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.pending-', dir=destination))
    report = {'createdAt': datetime.now(timezone.utc).isoformat(), 'databases': [], 'catalog': None}
    try:
        for path in sorted(directory.glob('*.sqlite3')):
            if path.is_symlink() or not path.is_file(): continue
            target = temporary / path.name
            source = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=30)
            replica = sqlite3.connect(target)
            try:
                source.backup(replica, pages=512, sleep=.05)
                if replica.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
                    raise ValueError('Unreadable database backup')
            finally:
                source.close()
                replica.close()
            target.chmod(0o600)
            report['databases'].append(path.name)
        manifest = directory / 'channel-catalog' / 'manifest.json'
        if manifest.is_file():
            raw = manifest.read_bytes()
            value = json.loads(raw)
            digest = value['sha256']
            if not re.fullmatch(r'[a-f0-9]{64}', digest): raise ValueError('Invalid snapshot identity')
            snapshot = manifest.parent / 'snapshots' / (digest + '.json.gz')
            if snapshot.is_symlink(): raise ValueError('Invalid snapshot path')
            if snapshot.stat().st_size != value['compressedBytes']: raise ValueError('Invalid snapshot size')
            data = snapshot.read_bytes()
            if hashlib.sha256(data).hexdigest() != digest: raise ValueError('Invalid snapshot checksum')
            catalog = temporary / 'channel-catalog'
            (catalog / 'snapshots').mkdir(parents=True)
            (catalog / 'manifest.json').write_bytes(raw)
            (catalog / 'snapshots' / snapshot.name).write_bytes(data)
            report['catalog'] = {'version':value['version'], 'sha256':digest}
        if not report['databases']: raise ValueError('No databases to back up')
        (temporary / 'verified.json').write_text(json.dumps(report))
        name = 'server-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        os.replace(temporary, destination / name)
        return {'backup':str(destination / name), **report}
    except BaseException:
        # Only this newly created staging directory is removed; existing verified
        # backups are retained. No automatic retention deletion is performed.
        shutil.rmtree(temporary)
        raise


if __name__ == '__main__':
    print(json.dumps(backup(Path(os.environ.get('BOBTV_DATA_DIR', Path(__file__).parent / 'data')))))
