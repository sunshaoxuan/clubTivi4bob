"""Run on ccnode against an uploaded staging directory, after dependency setup.

Preserves the deployed localized site and device APIs. Only scoped modules and
two named systemd units are replaced; SQLite is backed up before migrations.
"""
import hashlib
import json
import os
import py_compile
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

SITE = Path('/opt/bobtv/site')
DATA = Path('/var/lib/bobtv')
FILES = ('network_routes.py', 'catalog_inventory.py',
         'process_channel_inventory.py', 'update_network_databases.py',
         'network_probe_agent.py')
BASELINES = {
    'catalog_inventory.py': '0c1f5d83cb45eb8587c1a994c887db53201c4ebfd7370557878d7412386ac97d',
    'process_channel_inventory.py': '2622fd3e4e18c6b9b77ae0c7dfe849b96a302c3fac767c9659732f3812ed68a5',
}


def install(stage):
    stage = Path(stage).resolve()
    for name in FILES:
        source = stage / name
        if not source.is_file() or source.is_symlink(): raise ValueError('Missing staged module')
        py_compile.compile(str(source), doraise=True)
        if name in BASELINES:
            actual = hashlib.sha256((SITE / name).read_bytes()).hexdigest()
            replacement = hashlib.sha256(source.read_bytes()).hexdigest()
            if actual not in (BASELINES[name], replacement):
                raise ValueError('Deployed module changed since preflight: ' + name)
    app = SITE / 'app.py'
    text = app.read_text()
    if 'from network_routes import router as network_router' not in text:
        anchor = 'from server_jobs import router as server_task_router\n'
        if text.count(anchor) != 1: raise ValueError('Unexpected deployed API imports')
        text = text.replace(anchor, anchor + 'from network_routes import router as network_router\n')
        anchor = 'app.include_router(server_task_router)\n'
        if text.count(anchor) != 1: raise ValueError('Unexpected deployed API routers')
        text = text.replace(anchor, anchor + 'app.include_router(network_router)\n')
    sys.path.insert(0, str(SITE))
    from backup_server_data import backup
    evidence = backup(DATA)
    name = 'regional-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    code_backup = SITE.parent / 'backups' / name
    code_backup.mkdir(parents=True)
    targets = [SITE / filename for filename in FILES] + [app]
    units = ['bobtv-network-db.service', 'bobtv-network-db.timer']
    targets += [Path('/etc/systemd/system') / unit for unit in units]
    originals = {}
    for target in targets:
        originals[str(target)] = target.read_bytes() if target.exists() else None
        if target.exists(): shutil.copy2(target, code_backup / target.name)
    def replace(target, content):
        fd, temporary = tempfile.mkstemp(prefix='.regional-', dir=target.parent)
        with os.fdopen(fd, 'wb') as output:
            output.write(content)
        os.chmod(temporary, 0o644)
        os.replace(temporary, target)
    try:
        for filename in FILES: replace(SITE / filename, (stage / filename).read_bytes())
        replace(app, text.encode())
        for unit in units: replace(Path('/etc/systemd/system') / unit, (stage / unit).read_bytes())
        directory = DATA / 'network-db'
        directory.mkdir(exist_ok=True)
        shutil.chown(directory, user='bobtv', group='bobtv')
        subprocess.run(['/opt/bobtv/venv/bin/python', '-c', 'import app; print("regional routers imported")'], cwd=SITE, check=True)
        subprocess.run(['systemctl', 'daemon-reload'], check=True)
        subprocess.run(['systemctl', 'restart', 'bobtv.service'], check=True)
        subprocess.run(['systemctl', 'is-active', '--quiet', 'bobtv.service'], check=True)
        subprocess.run(['systemctl', 'enable', '--now', 'bobtv-network-db.timer'], check=True)
        subprocess.run(['systemctl', 'start', '--no-block', 'bobtv-network-db.service'], check=True)
    except BaseException:
        for filename, content in originals.items():
            target = Path(filename)
            if content is not None: replace(target, content)
            elif target.exists(): target.unlink()
        subprocess.run(['systemctl', 'daemon-reload'], check=False)
        subprocess.run(['systemctl', 'restart', 'bobtv.service'], check=False)
        raise
    report = {'databaseBackup': evidence, 'codeBackup': str(code_backup),
              'modules': {name: hashlib.sha256((SITE / name).read_bytes()).hexdigest() for name in FILES}}
    (code_backup / 'deployment.json').write_text(json.dumps(report))
    print(json.dumps(report))


if __name__ == '__main__': install(sys.argv[1])
