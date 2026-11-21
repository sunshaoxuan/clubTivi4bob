"""Prepare private EPG reads and cache bypasses without activating the cutover."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess

from deploy_resource_relay import ROOT, ssh, upload


INSTALL = r'''
import grp,hashlib,json,os,secrets,shutil,subprocess,sys,time,urllib.request
from pathlib import Path
p=json.load(sys.stdin);stage=Path(p['stage']);origin=p['origin']
backup=Path('/opt/bobtv/backups' if origin else '/opt/bobtv-relay/backups')/('catalog-access-'+str(int(time.time())))
backup.mkdir(parents=True,mode=0o700)
existing={}
for index,item in enumerate(p['files']):
 target=Path(item['target']);source=stage/item['name']
 assert hashlib.sha256(source.read_bytes()).hexdigest()==item['sha256'],'Staged source mismatch'
 existing[str(target)]=target.exists()
 if target.exists():
  assert hashlib.sha256(target.read_bytes()).hexdigest() in item['previous'],'Live file differs from reviewed baseline: '+target.name
  shutil.copy2(target,backup/str(index))
services=['bobtv','bobtv-epg-api'] if origin else ['bobtv-resource-relay']
try:
 if origin:
  key=Path('/etc/bobtv/epg-internal-read.key')
  if not key.exists():
   fd=os.open(key,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o640)
   with os.fdopen(fd,'wb') as out:out.write(secrets.token_bytes(32))
  assert not key.is_symlink() and key.stat().st_size==32 and key.stat().st_uid==0,'Invalid internal read key'
  os.chown(key,0,grp.getgrnam('bobtv').gr_gid);os.chmod(key,0o640)
 for item in p['files']:
  target=Path(item['target']);temporary=target.with_name('.catalog-access-'+secrets.token_hex(8))
  temporary.write_bytes((stage/item['name']).read_bytes());os.chmod(temporary,0o644);os.replace(temporary,target)
 if not origin:subprocess.run(['nginx','-t'],check=True)
 python='/opt/bobtv/venv/bin/python' if origin else '/opt/bobtv-relay/venv/bin/python'
 folder='/opt/bobtv/site' if origin else '/opt/bobtv-relay'
 modules='import epg_api,epg_store,epg_runtime_health,catalog_access' if origin else 'import resource_relay'
 subprocess.run([python,'-c',modules],cwd=folder,check=True)
 for service in services:subprocess.run(['systemctl','restart',service],check=True)
 if not origin:subprocess.run(['systemctl','reload','nginx'],check=True)
 endpoints=['http://127.0.0.1:8917/api/v1/epg/manifest','http://127.0.0.1:8918/api/v1/epg/manifest'] if origin else ['http://127.0.0.1:8927/bobtv/api/v1/resource-node/probe']
 for endpoint in endpoints:
  for attempt in range(25):
   try:
    with urllib.request.urlopen(endpoint,timeout=3) as response:assert response.status==200;response.read(65536)
    break
   except (OSError,AssertionError):
    if attempt==24:raise
    time.sleep(1)
 print(json.dumps(dict(prepared=True,cutoverActivated=False,backup=str(backup),restartedServices=services,
  epgWorkerTimersRestarted=False,files={item['target']:item['sha256'] for item in p['files']})))
except BaseException:
 for index,item in enumerate(p['files']):
  target=Path(item['target'])
  if existing[str(target)]:shutil.copy2(backup/str(index),target)
  else:target.unlink(missing_ok=True)
 if not origin:subprocess.run(['nginx','-t']);subprocess.run(['systemctl','reload','nginx'])
 for service in services:subprocess.run(['systemctl','restart',service])
 raise
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    baseline = '6412724171b178c883e53c5171b95db0f8b99dcc'
    groups = {
        'ccnode.briconbric.com': [('internal_epg_auth.py', '/opt/bobtv/site/internal_epg_auth.py'),
            *[(name, '/opt/bobtv/site/' + name) for name in
              ['epg_store.py', 'epg_runtime_health.py', 'catalog_access.py', 'epg_api.py']]],
        'cndrp.com': [('resource_relay.py', '/opt/bobtv-relay/resource_relay.py'),
            ('deploy/bobtv-resource-relay-cache.conf', '/etc/nginx/conf.d/bobtv-resource-cache.conf')],
    }
    results = {}
    for host, files in groups.items():
        stage = ssh(host, 'mktemp -d /opt/bobtv-access-stage-XXXXXX').strip()
        upload(host, stage, [ROOT/'website'/name for name, _ in files])
        payload = []
        for name, target in files:
            current = (ROOT/'website'/name).read_bytes()
            digest = hashlib.sha256(current).hexdigest()
            previous = [digest]
            if name != 'internal_epg_auth.py':
                old = subprocess.check_output(['git', 'show', baseline + ':website/' + name], cwd=ROOT)
                previous.append(hashlib.sha256(old).hexdigest())
                if name == 'epg_api.py':
                    previous.append(hashlib.sha256(old.replace(b'from catalog_access import install\n', b'')
                        .replace(b'install(app)\n', b'')).hexdigest())
            payload.append(dict(name=Path(name).name, target=target, sha256=digest, previous=previous))
        results[host] = json.loads(ssh(host, 'python3 -c '+shlex.quote(INSTALL),
            json.dumps(dict(stage=stage, origin=host.startswith('ccnode.'), files=payload))))
        args.receipt.write_text(json.dumps(results, indent=2)+'\n')
        print(host, 'prepared; anonymous cutover remains inactive', flush=True)


if __name__ == '__main__':
    main()
