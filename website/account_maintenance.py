"""Account-only cleanup and consistent SQLite backups, run as bobtv daily.

Backups include personal data. They must remain private and expire after 30 days.
No subscription/catalogue databases are touched by this job.
"""
import os
import sqlite3
import time
from pathlib import Path
from accounts import database


def maintain():
    now = int(time.time())
    with database() as db:
        db.execute('DELETE FROM sessions WHERE expires<=?', (now,))
        db.execute('DELETE FROM codes WHERE expires<=?', (now,))
        db.execute('DELETE FROM oauth WHERE expires<=?', (now,))
        db.execute('DELETE FROM limits WHERE expires<=?', (now,))
    root = Path(os.environ.get('BOBTV_DATA_DIR', Path(__file__).parent/'data'))
    backups = root/'account-backups'
    backups.mkdir(mode=0o700, exist_ok=True)
    os.chmod(backups, 0o700)
    for path in backups.glob('accounts-*.sqlite3'):
        if path.stat().st_mtime < now - 30*86400:
            path.unlink()
    path = backups/('accounts-'+time.strftime('%Y%m%d',time.gmtime(now))+'.sqlite3')
    fd = os.open(path, os.O_CREAT | os.O_WRONLY, 0o600)
    os.close(fd)
    with sqlite3.connect(root/'accounts.sqlite3') as src, sqlite3.connect(path) as dst:
        src.backup(dst)
    print('Account maintenance completed.')


if __name__ == '__main__':maintain()
