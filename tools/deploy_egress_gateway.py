"""Scoped server deployment preserving localized pages and other API routers."""
import hashlib
import json
import os
from pathlib import Path
import py_compile
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

SITE = Path('/opt/bobtv/site')
DATA = Path('/var/lib/bobtv')
MODULES = ('egress_gateway.py', 'dash_relay.py', 'network_routes.py', 'refresh_egress_resources.py')
UNITS = ('bobtv-egress-resources.service', 'bobtv-egress-resources.timer')


def install(stage):
    stage = Path(stage).resolve()
    for name in MODULES: py_compile.compile(str(stage / name), doraise=True)
    original = (SITE / 'app.py').read_text()
    text = original
    if 'from egress_gateway import router as egress_router' not in text:
        anchor = 'from network_routes import router as network_router\n'
        if text.count(anchor) != 1: raise ValueError('Unexpected live router imports')
        text = text.replace(anchor, anchor + 'from egress_gateway import router as egress_router\n')
        anchor = 'app.include_router(network_router)\n'
        if text.count(anchor) != 1: raise ValueError('Unexpected live router registration')
        text = text.replace(anchor, anchor + 'app.include_router(egress_router)\n')
    previous = hashlib.sha256((SITE / 'network_routes.py').read_bytes()).hexdigest()
    replacement = hashlib.sha256((stage / 'network_routes.py').read_bytes()).hexdigest()
    if previous not in ('861a1f8cb44fdf324e3b591d7494de61918ae3b5ee01d20c0f49e215171d3b7b', replacement):
        raise ValueError('Live regional module changed since preflight')
    sys.path.insert(0, str(SITE))
    from backup_server_data import backup
    evidence = backup(DATA)
    backup_path = SITE.parent / 'backups' / ('egress-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
    backup_path.mkdir()
    targets = [SITE / name for name in (*MODULES, 'app.py')]
    targets += [Path('/etc/systemd/system') / unit for unit in UNITS]
    saved = {path: path.read_bytes() if path.exists() else None for path in targets}
    for path in targets:
        if path.exists(): shutil.copy2(path, backup_path / path.name)
    def replace(path, content):
        fd, temporary = tempfile.mkstemp(prefix='.egress-', dir=path.parent)
        with os.fdopen(fd, 'wb') as output: output.write(content)
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    try:
        for name in MODULES: replace(SITE / name, (stage / name).read_bytes())
        replace(SITE / 'app.py', text.encode())
        for unit in UNITS: replace(Path('/etc/systemd/system') / unit, (stage / unit).read_bytes())
        subprocess.run(['/opt/bobtv/venv/bin/python', '-c', 'import app; from catalog_inventory import database; c=database(); c.__enter__(); c.__exit__(None,None,None)'], cwd=SITE, check=True)
        subprocess.run(['systemctl', 'daemon-reload'], check=True)
        subprocess.run(['systemctl', 'restart', 'bobtv.service'], check=True)
        subprocess.run(['systemctl', 'is-active', '--quiet', 'bobtv.service'], check=True)
        subprocess.run(['systemctl', 'enable', '--now', 'bobtv-egress-resources.timer'], check=True)
        subprocess.run(['systemctl', 'start', '--no-block', 'bobtv-egress-resources.service'], check=True)
    except BaseException:
        for path, content in saved.items():
            if content is not None: replace(path, content)
            elif path.exists(): path.unlink()
        subprocess.run(['systemctl', 'daemon-reload'], check=False)
        subprocess.run(['systemctl', 'restart', 'bobtv.service'], check=False)
        raise
    report = {'databaseBackup': evidence, 'codeBackup': str(backup_path),
        'modules': {name: hashlib.sha256((SITE / name).read_bytes()).hexdigest() for name in MODULES}}
    (backup_path / 'deployment.json').write_text(json.dumps(report))
    print(json.dumps(report))


if __name__ == '__main__': install(sys.argv[1])
