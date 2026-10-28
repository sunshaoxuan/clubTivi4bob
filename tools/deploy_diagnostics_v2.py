"""Scoped, hash-guarded deployment. Default is a read-only preflight.

No EPG workers, mail configuration, release feeds or desktop applications are
changed. Source and service backups precede every replacement. Existing relay
secrets stay on the server. Diagnostic bodies live outside catalog backups.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import time

from deploy_resource_relay import ROOT, ssh, upload

ORIGIN = 'ccnode.briconbric.com'
RELAY = 'cndrp.com'

PREFLIGHT = r'''
import hashlib,json,os,sqlite3,subprocess
from pathlib import Path
role=os.environ['BOBTV_DEPLOY_ROLE'];root=Path('/opt/bobtv/site' if role=='origin' else '/opt/bobtv-relay')
names=['app.py','catalog_inventory.py','privacy.html'] if role=='origin' else ['resource_relay.py']
result={'role':role,'files':{n:hashlib.sha256((root/n).read_bytes()).hexdigest() for n in names},'service':subprocess.check_output(['systemctl','is-active','bobtv.service' if role=='origin' else 'bobtv-resource-relay.service'],text=True).strip()}
if role=='origin':
 with sqlite3.connect('file:/var/lib/bobtv/channel_inventory.sqlite3?mode=ro',uri=True,timeout=2) as c:
  result['inventoryRoutes']=c.execute('select count(*) from routes').fetchone()[0]
else:
 import httpx
 result['httpxVersion']=httpx.__version__
print(json.dumps(result))
'''

INSTALL = r'''
import hashlib,json,os,pwd,shutil,sqlite3,subprocess,sys,time
from pathlib import Path
p=json.load(sys.stdin);role=p['role'];stage=Path(p['stage'])
root=Path('/opt/bobtv/site' if role=='origin' else '/opt/bobtv-relay')
backup=Path('/opt/bobtv/backups' if role=='origin' else '/opt/bobtv-relay/backups')/('diagnostics-v2-'+time.strftime('%Y%m%dT%H%M%SZ',time.gmtime()))
backup.mkdir(parents=True,mode=0o700)
for name,expected in p['before']['files'].items():
 path=root/name
 if hashlib.sha256(path.read_bytes()).hexdigest()!=expected:raise RuntimeError('Deployed source changed since preflight: '+name)
 shutil.copy2(path,backup/name)
service='bobtv.service' if role=='origin' else 'bobtv-resource-relay.service'
timer='bobtv-diagnostic-maintenance.timer' if role=='origin' else 'bobtv-diagnostics-relay.timer'
unit=timer.replace('.timer','.service')
timer_was_enabled=subprocess.run(['systemctl','is-enabled','--quiet',timer],capture_output=True).returncode==0
timer_was_active=subprocess.run(['systemctl','is-active','--quiet',timer],capture_output=True).returncode==0
drop=Path('/etc/systemd/system')/(service+'.d')/'diagnostics-v2.conf'
targets=[drop,Path('/etc/systemd/system')/timer,Path('/etc/systemd/system')/unit]
restore=[]
def remember(path):
 existed=path.exists();name='file-'+hashlib.sha256(str(path).encode()).hexdigest()[:12]
 if existed:shutil.copy2(path,backup/name)
 restore.append((str(path),name,existed))
def atomic(path,data):
 path.parent.mkdir(parents=True,exist_ok=True)
 temp=path.with_name('.'+path.name+'.diagnostics-v2.tmp')
 temp.write_bytes(data);os.chmod(temp,0o644);os.replace(temp,path)
if role=='origin':
 src=sqlite3.connect('file:/var/lib/bobtv/channel_inventory.sqlite3?mode=ro',uri=True,timeout=5)
 dst=sqlite3.connect(backup/'channel_inventory.sqlite3')
 src.backup(dst,pages=1024,sleep=.02)
 if dst.execute('PRAGMA quick_check').fetchone()[0]!='ok':raise RuntimeError('Inventory backup failed integrity check')
 dst.close();src.close()
 code=['diagnostic_store.py','diagnostics_api.py','catalog_event_queue.py','diagnostic_maintenance.py','catalog_inventory.py']
else:code=['diagnostic_store.py','diagnostics_api.py','diagnostic_relay_worker.py','resource_relay.py']
for name in code:remember(root/name)
for target in targets:remember(target)
try:
 for name in code:atomic(root/name,(stage/name).read_bytes())
 if role=='origin':
  app=(root/'app.py').read_text()
  if 'from diagnostics_api import router as diagnostics_router' not in app:
   anchor='from catalog_inventory import router as inventory_router'
   if app.count(anchor)!=1:raise RuntimeError('Unexpected live app import anchor')
   app=app.replace(anchor,anchor+'\nfrom diagnostics_api import router as diagnostics_router')
   anchor='app.include_router(inventory_router)'
   if app.count(anchor)!=1:raise RuntimeError('Unexpected live app router anchor')
   app=app.replace(anchor,anchor+'\napp.include_router(diagnostics_router)')
  atomic(root/'app.py',app.encode())
  privacy=(root/'privacy.html').read_text()
  if 'id="diagnostics-v2"' not in privacy:
   if privacy.count('</div></main>')!=1:raise RuntimeError('Unexpected privacy page anchor')
   privacy=privacy.replace('</div></main>',(stage/'diagnostics_v2_policy_fragment.html').read_text()+'\n</div></main>')
   atomic(root/'privacy.html',privacy.encode())
  owner=pwd.getpwnam('bobtv');data=Path('/var/lib/bobtv-diagnostics');data.mkdir(exist_ok=True,mode=0o700);os.chown(data,owner.pw_uid,owner.pw_gid);os.chmod(data,0o700)
  atomic(drop,b'[Service]\nEnvironment=BOBTV_DIAGNOSTICS_DIR=/var/lib/bobtv-diagnostics\nReadWritePaths=/var/lib/bobtv-diagnostics\n')
 else:
  owner=pwd.getpwnam('bobtv-relay');data=Path('/var/lib/bobtv-relay');data.mkdir(exist_ok=True,mode=0o700);os.chown(data,owner.pw_uid,owner.pw_gid)
  atomic(drop,b'[Service]\nStateDirectory=bobtv-relay\nReadWritePaths=/var/lib/bobtv-relay\n')
 for name in [timer,unit]:atomic(Path('/etc/systemd/system')/name,(stage/name).read_bytes())
 runtime='/opt/bobtv/venv/bin/python' if role=='origin' else '/opt/bobtv-relay/venv/bin/python'
 check='import app,diagnostics_api,catalog_event_queue' if role=='origin' else 'import resource_relay,diagnostic_relay_worker'
 subprocess.run([runtime,'-c',check],cwd=root,check=True,timeout=30)
 subprocess.run(['systemctl','daemon-reload'],check=True,timeout=20)
 subprocess.run(['systemctl','restart',service],check=True,timeout=30)
 subprocess.run(['systemctl','is-active','--quiet',service],check=True,timeout=10)
 subprocess.run(['systemctl','enable','--now',timer],check=True,timeout=20)
 receipt={'role':role,'backup':str(backup),'service':'active','timer':timer,'sourceHashes':{n:hashlib.sha256((root/n).read_bytes()).hexdigest() for n in code},'inventoryBackupVerified':role=='origin'}
 (backup/'receipt.json').write_text(json.dumps(receipt))
 print(json.dumps(receipt))
except Exception:
 # Only task-owned files and the two named BobTV services are restored.
 subprocess.run(['systemctl','disable','--now',timer],capture_output=True)
 for target,name,existed in restore:
  target=Path(target)
  if existed:atomic(target,(backup/name).read_bytes())
  elif target.exists():target.unlink()
 for name in p['before']['files']:atomic(root/name,(backup/name).read_bytes())
 subprocess.run(['systemctl','daemon-reload'],check=False)
 if timer_was_enabled:subprocess.run(['systemctl','enable',timer],capture_output=True)
 if timer_was_active:subprocess.run(['systemctl','start',timer],capture_output=True)
 subprocess.run(['systemctl','restart',service],check=False)
 raise
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--deploy', action='store_true')
    parser.add_argument('--receipt-dir', type=Path)
    args = parser.parse_args()
    checks = {}
    for host, role in [(ORIGIN, 'origin'), (RELAY, 'relay')]:
        runtime = '/opt/bobtv/venv/bin/python' if role == 'origin' else '/opt/bobtv-relay/venv/bin/python'
        checks[host] = json.loads(ssh(host, 'BOBTV_DEPLOY_ROLE=' + role + ' ' + runtime + ' -c ' + shlex.quote(PREFLIGHT)))
    # Never replace unrelated or newer live catalogue/relay logic.
    for host, name in [(ORIGIN, 'catalog_inventory.py'), (RELAY, 'resource_relay.py')]:
        baseline = subprocess.check_output(['git', 'show', 'HEAD:website/' + name], cwd=ROOT)
        if checks[host]['files'][name] != hashlib.sha256(baseline).hexdigest():
            raise RuntimeError('Live ' + name + ' differs from the tracked baseline; reconcile before deploying')
    print(json.dumps({'preflight': checks, 'willDeploy': args.deploy}), flush=True)
    if not args.deploy:
        return
    receipts = []
    for host, role in [(ORIGIN, 'origin'), (RELAY, 'relay')]:
        stage = ssh(host, 'mktemp -d /opt/bobtv-diagnostics-stage-XXXXXX').strip()
        names = (['diagnostic_store.py', 'diagnostics_api.py', 'catalog_event_queue.py', 'diagnostic_maintenance.py', 'catalog_inventory.py', 'diagnostics_v2_policy_fragment.html']
                 if role == 'origin' else ['diagnostic_store.py', 'diagnostics_api.py', 'diagnostic_relay_worker.py', 'resource_relay.py'])
        timers = ['bobtv-diagnostic-maintenance'] if role == 'origin' else ['bobtv-diagnostics-relay']
        files = [ROOT / 'website' / name for name in names]
        files.extend(ROOT / 'website/deploy' / (stem + suffix) for stem in timers for suffix in ['.service', '.timer'])
        upload(host, stage, files)
        result = ssh(host, ('/opt/bobtv/venv/bin/python' if role == 'origin' else '/opt/bobtv-relay/venv/bin/python') + ' -c ' + shlex.quote(INSTALL),
                     json.dumps({'role': role, 'stage': stage, 'before': checks[host]}))
        receipt = json.loads(result)
        receipts.append(receipt)
        print(json.dumps(receipt), flush=True)
    if args.receipt_dir:
        args.receipt_dir.mkdir(parents=True, exist_ok=True)
        (args.receipt_dir / 'deployment.json').write_text(json.dumps({'preflight': checks, 'receipts': receipts}, indent=2))


if __name__ == '__main__':
    main()
