"""Deploy route ownership events without changing live page templates or apps."""
import json
import shlex
from deploy_resource_relay import ROOT, ssh, upload

INSTALL = r'''
import hashlib,json,os,shutil,subprocess,sys,time
from pathlib import Path
stage=Path(json.load(sys.stdin)['stage']);site=Path('/opt/bobtv/site')
os.environ['BOBTV_DATA_DIR']='/var/lib/bobtv'
sys.path.insert(0,str(site))
from backup_server_data import backup
verified=backup(Path('/var/lib/bobtv'))
saved=Path('/opt/bobtv/backups')/('route-transfer-'+time.strftime('%Y%m%dT%H%M%SZ',time.gmtime()))
saved.mkdir(parents=True)
names=['catalog_inventory.py','process_channel_inventory.py','publish_channel_catalog.py']
for name in names: shutil.copy2(site/name,saved/name)
try:
    for name in names: shutil.copy2(stage/name,site/name)
    subprocess.run(['/opt/bobtv/venv/bin/python','-c',
        'import app; from catalog_inventory import database; '
        'from pathlib import Path; '
        'with_database=database(Path("/var/lib/bobtv")); '
        'conn=with_database.__enter__(); '
        'assert conn.execute("PRAGMA quick_check").fetchone()[0]=="ok"; '
        'with_database.__exit__(None,None,None)'],cwd=site,check=True)
    subprocess.run(['systemctl','restart','bobtv.service'],check=True)
    subprocess.run(['systemctl','is-active','--quiet','bobtv.service'],check=True)
except BaseException:
    for name in names: shutil.copy2(saved/name,site/name)
    subprocess.run(['systemctl','restart','bobtv.service'],check=False)
    raise
print(json.dumps({'verifiedBackup':verified['backup'],'codeBackup':str(saved),
    'service':'active','files':{name:hashlib.sha256((site/name).read_bytes()).hexdigest() for name in names}}))
'''


def main():
    host = 'ccnode.briconbric.com'
    stage = ssh(host, 'mktemp -d /opt/bobtv-route-transfer-XXXXXX').strip()
    upload(host, stage, [ROOT/'website'/name for name in
        ['catalog_inventory.py', 'process_channel_inventory.py', 'publish_channel_catalog.py']])
    print(ssh(host, 'python3 -c '+shlex.quote(INSTALL), json.dumps({'stage': stage})))


if __name__ == '__main__':
    main()
