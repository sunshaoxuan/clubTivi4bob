"""Install authenticated regional sync without replacing the live catalog worker."""
import argparse
import io
import json
from pathlib import Path
import shlex
import tarfile

from deploy_resource_relay import ROOT, ssh

INSTALL = r'''
import grp,json,os,secrets,shutil,subprocess,time,urllib.request
from pathlib import Path
stage=Path(STAGE);site=Path('/opt/bobtv/site')
backup=Path('/opt/bobtv/backups')/('regional-sync-'+str(int(time.time())))
backup.mkdir(mode=0o700)
drop=Path('/etc/systemd/system/bobtv.service.d/20-regional-catalog.conf')
files=[site/'regional_catalog_sync.py',site/'catalog_access.py',site/'app.py',drop]
existed={str(p):p.exists() for p in files}
for i,p in enumerate(files):
 if p.exists():shutil.copy2(p,backup/str(i))
(backup/'manifest.json').write_text(json.dumps([str(p) for p in files]))
key=Path('/etc/bobtv/regional-catalog-signing.key')
if not key.exists():
 fd=os.open(key,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o640)
 with os.fdopen(fd,'wb') as out:out.write(secrets.token_bytes(32))
 os.chown(key,0,grp.getgrnam('bobtv').gr_gid)
try:
 for name in ['regional_catalog_sync.py','catalog_access.py']:shutil.copy2(stage/name,site/name)
 text=(site/'app.py').read_text()
 anchor='from accounts import router as account_router'
 if 'from regional_catalog_sync import router as regional_catalog_router' not in text:
  if text.count(anchor)!=1:raise RuntimeError('Live account import changed')
  text=text.replace(anchor,anchor+'\nfrom regional_catalog_sync import router as regional_catalog_router\nfrom catalog_access import install as install_catalog_access')
 if 'app.include_router(regional_catalog_router)' not in text:
  anchor='app.include_router(account_router)'
  if text.count(anchor)!=1:raise RuntimeError('Live account router changed')
  text=text.replace(anchor,'install_catalog_access(app)\n'+anchor+'\napp.include_router(regional_catalog_router)')
 (site/'app.py').write_text(text)
 drop.parent.mkdir(exist_ok=True)
 drop.write_text('[Service]\nEnvironment=BOBTV_REGIONAL_CATALOG_SIGNING_KEY=/etc/bobtv/regional-catalog-signing.key\n')
 subprocess.run(['/opt/bobtv/venv/bin/python','-c','import app'],cwd=site,check=True,stdout=subprocess.DEVNULL)
 subprocess.run(['systemctl','daemon-reload'],check=True)
 subprocess.run(['systemctl','restart','bobtv'],check=True)
 for n in range(30):
  try:
   with urllib.request.urlopen('http://127.0.0.1:8917/api/v1/regional-catalog/bootstrap.bobtv',timeout=3) as r:bootstrap=json.load(r)
   assert bootstrap['format']=='bobtv-sync-bootstrap' and 'channels' not in bootstrap
   break
  except (OSError,AssertionError):
   if n==29:raise
   time.sleep(1)
 print(json.dumps(dict(deployed=True,backup=str(backup),keyId=bootstrap['keyId'],
    anonymousCatalogCutover=False,existingCatalogWorkersPreserved=True)))
except BaseException:
 for i,p in enumerate(files):
  if existed[str(p)]:shutil.copy2(backup/str(i),p)
  else:p.unlink(missing_ok=True)
 subprocess.run(['systemctl','daemon-reload']);subprocess.run(['systemctl','restart','bobtv']);raise
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    stage = ssh('ccnode.briconbric.com', 'mktemp -d /opt/bobtv-regional-stage-XXXXXX').strip()
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w') as archive:
        for name in ['regional_catalog_sync.py','catalog_access.py']:
            archive.add(ROOT/'website'/name, arcname=name)
    ssh('ccnode.briconbric.com', 'tar -xf - -C '+shlex.quote(stage), data.getvalue())
    result = ssh('ccnode.briconbric.com', 'python3 -c '+shlex.quote(INSTALL.replace('STAGE', repr(stage))))
    args.receipt.write_text(result)
    print(result)


if __name__ == '__main__': main()
