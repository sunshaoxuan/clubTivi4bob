"""Scoped identity-service deployment. Never prints or checks secrets into Git.

Uses the existing authorized SSH transport. Account config is transferred via
stdin. Unrelated public pages, catalogue/runtime and release binaries stay intact.
"""
import argparse
import io
import json
import shlex
import tarfile
from pathlib import Path

from deploy_resource_relay import ROOT, ssh

FILES = ['website/accounts.py', 'website/account_admin.html', 'website/account_admin.js',
         'website/account_admin.css', 'website/account_maintenance.py',
         'website/deploy/bobtv-accounts-maintenance.service','website/deploy/bobtv-accounts-maintenance.timer']
INSTALL = r'''
import grp,json,os,secrets,shutil,sqlite3,subprocess,sys,time,urllib.request
from pathlib import Path
payload=json.load(sys.stdin);stage=Path(payload['stage']);site=Path('/opt/bobtv/site')
backup=Path('/opt/bobtv/backups')/('accounts-'+time.strftime('%Y%m%dT%H%M%SZ',time.gmtime()))
backup.mkdir(parents=True,mode=0o700)
config=Path('/etc/bobtv/accounts.json')
paths=[site/name for name in ['app.py','accounts.py','account_admin.html','account_admin.js','account_admin.css','account_maintenance.py','requirements.txt','templates/privacy.html','privacy.html']]
paths += list((site/'locales').glob('*.json'))
paths += [config,site/'backup_server_data.py',Path('/etc/systemd/system/bobtv-accounts-maintenance.service'),Path('/etc/systemd/system/bobtv-accounts-maintenance.timer')]
existed={}
for i,path in enumerate(paths):
 existed[str(path)]=path.exists()
 if path.exists():shutil.copy2(path,backup/str(i))
(backup/'manifest.json').write_text(json.dumps([str(p) for p in paths]))
try:
 subprocess.run(['/opt/bobtv/venv/bin/pip','install','--disable-pip-version-check','--only-binary=:all:','PyJWT[crypto]>=2.10,<3'],check=True,stdout=subprocess.DEVNULL)
 for name in ['accounts.py','account_admin.html','account_admin.js','account_admin.css','account_maintenance.py']:
  shutil.copy2(stage/'website'/name,site/name)
 text=(site/'app.py').read_text()
 if 'from accounts import router as account_router' not in text:
  anchor='from source_registry import router as source_router'
  if text.count(anchor)!=1:raise RuntimeError('Live import anchor changed')
  text=text.replace(anchor,'from accounts import router as account_router\n'+anchor)
 if 'app.include_router(account_router)' not in text:
  anchor='app.include_router(source_router)'
  if text.count(anchor)!=1:raise RuntimeError('Live router anchor changed')
  text=text.replace(anchor,'app.include_router(account_router)\n'+anchor)
 (site/'app.py').write_text(text)
 general=site/'backup_server_data.py'
 if general.exists():
  content=general.read_text()
  if "if path.name == 'accounts.sqlite3'" not in content:
   anchor="        for path in sorted(directory.glob('*.sqlite3')):"
   if content.count(anchor)!=1:raise RuntimeError('Live backup anchor changed')
   content=content.replace(anchor,anchor+"\n            if path.name == 'accounts.sqlite3': continue")
   general.write_text(content)
 requirements=site/'requirements.txt'
 if 'PyJWT' not in requirements.read_text():requirements.write_text(requirements.read_text()+'\nPyJWT[crypto]>=2.10,<3\n')
 for lang,entries in payload['privacy'].items():
  path=site/'locales'/(lang+'.json');data=json.loads(path.read_text());data['account_privacy']=entries
  path.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
 path=site/'templates/privacy.html';text=path.read_text()
 if 'id="accounts"' in text:
  begin=text.index('<section class="download-help" id="accounts"');end=text.index('</section>',begin)+len('</section>')
  text=text[:begin]+text[end:]
 anchor='</div></main>'
 if text.count(anchor)!=1:raise RuntimeError('Live privacy container anchor changed')
 text=text.replace(anchor,payload['privacy_template']+'\n'+anchor)
 path.write_text(text)
 path=site/'privacy.html'
 if path.exists():
  text=path.read_text()
  if 'id="accounts"' not in text:text=text.replace('</main>',payload['privacy_fallback']+'</main>')
  else:
   start=text.index('<section id="accounts"');end=text.index('</section>',start)+len('</section>')
   text=text[:start]+payload['privacy_fallback']+text[end:]
  path.write_text(text)
 values=json.loads(config.read_text()) if config.exists() else {}
 values.setdefault('secret',secrets.token_hex(48));values.setdefault('origin','https://bobtv.briconbric.com')
 values.update(payload['credentials'])
 temp=config.with_suffix('.tmp');temp.write_text(json.dumps(values));os.chmod(temp,0o640);os.chown(temp,0,grp.getgrnam('bobtv').gr_gid);os.replace(temp,config)
 subprocess.run(['/opt/bobtv/venv/bin/python','-c','import app'],cwd=site,check=True,stdout=subprocess.DEVNULL)
 subprocess.run(['systemctl','restart','bobtv.service'],check=True)
 for n in range(15):
  try:
   with urllib.request.urlopen('http://127.0.0.1:8917/api/v1/account/config',timeout=3) as r:capabilities=json.load(r)
   break
  except OSError:
   if n==14:raise
   time.sleep(1)
 subprocess.run(['systemctl','is-active','--quiet','bobtv.service'],check=True)
 for name in ['bobtv-accounts-maintenance.service','bobtv-accounts-maintenance.timer']:
  shutil.copy2(stage/'website/deploy'/name,Path('/etc/systemd/system')/name)
 subprocess.run(['systemctl','daemon-reload'],check=True)
 subprocess.run(['systemctl','enable','--now','bobtv-accounts-maintenance.timer'],check=True,stdout=subprocess.DEVNULL)
 subprocess.run(['systemctl','start','bobtv-accounts-maintenance.service'],check=True)
 print(json.dumps({'deployed':True,'backup':str(backup),'capabilities':capabilities,'adminPath':'/admin'}))
except BaseException:
 subprocess.run(['systemctl','disable','--now','bobtv-accounts-maintenance.timer'],check=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 for i,path in enumerate(paths):
  if existed[str(path)]:shutil.copy2(backup/str(i),path)
  elif path.exists():path.unlink()
 subprocess.run(['systemctl','restart','bobtv.service'],check=False)
 raise
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', default='ccnode.briconbric.com')
    parser.add_argument('--credentials', type=Path, default=Path.home()/'.config/bobtv/accounts-secrets.json')
    args = parser.parse_args()
    credentials = json.loads(args.credentials.read_text()) if args.credentials.exists() else {}
    allowed = {'smtp_host','smtp_port','smtp_user','smtp_from','smtp_password','google_client_id',
               'google_client_secret','apple_client_id','apple_team_id','apple_key_id','apple_private_key'}
    if not set(credentials).issubset(allowed):raise ValueError('Unexpected credential fields')
    stage = ssh(args.host, 'mktemp -d /opt/bobtv-accounts-XXXXXX').strip()
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive,mode='w') as tar:
        for relative in FILES:tar.add(ROOT/relative,arcname=relative)
    ssh(args.host,'tar -xf - -C '+shlex.quote(stage),archive.getvalue())
    privacy = {p.stem:json.loads(p.read_text())['account_privacy'] for p in (ROOT/'website/locales').glob('*.json')}
    template = (ROOT/'website/templates/privacy.html').read_text()
    begin=template.index('<section class="download-help" id="accounts"')
    template = template[begin:template.index('</section>',begin)+len('</section>')]
    fallback=(ROOT/'website/privacy.html').read_text();begin=fallback.index('<section id="accounts"');fallback=fallback[begin:fallback.index('</section>',begin)+len('</section>')]
    print(ssh(args.host,'python3 -c '+shlex.quote(INSTALL),json.dumps({'stage':stage,'credentials':credentials,'privacy':privacy,'privacy_template':template,'privacy_fallback':fallback})))


if __name__=='__main__':main()
