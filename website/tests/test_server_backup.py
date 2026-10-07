import hashlib
import json
import sqlite3
import sys
from pathlib import Path
import pytest
sys.path.insert(0, str(Path(__file__).parents[1]))
from backup_server_data import backup


def test_online_backup_is_readable_and_preserves_exact_catalog(tmp_path):
    with sqlite3.connect(tmp_path/'server_tasks.sqlite3') as conn:
        conn.execute('CREATE TABLE tasks(id INTEGER)')
        conn.execute('INSERT INTO tasks VALUES (1)')
    data = b'test snapshot bytes'
    digest = hashlib.sha256(data).hexdigest()
    catalog = tmp_path/'channel-catalog'
    (catalog/'snapshots').mkdir(parents=True)
    (catalog/'snapshots'/(digest+'.json.gz')).write_bytes(data)
    manifest = {'version':'test','sha256':digest,'compressedBytes':len(data)}
    (catalog/'manifest.json').write_text(json.dumps(manifest))
    result = backup(tmp_path)
    directory = Path(result['backup'])
    with sqlite3.connect(directory/'server_tasks.sqlite3') as conn:
        assert conn.execute('SELECT id FROM tasks').fetchone()[0] == 1
    assert (directory/'channel-catalog'/'manifest.json').read_bytes() == (catalog/'manifest.json').read_bytes()
    assert json.loads((directory/'verified.json').read_text())['catalog']['sha256'] == digest
    (catalog/'snapshots'/(digest+'.json.gz')).write_bytes(b'corrupted')
    with pytest.raises(ValueError): backup(tmp_path)
    assert directory.exists() and not list((tmp_path/'backups').glob('.pending-*'))
