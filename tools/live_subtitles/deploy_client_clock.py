"""Deploy the text-only pilot alongside existing clients, retaining rollback."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
from deploy import FILES, ROOT
REMOTE=r'''
import pathlib,tarfile,json,subprocess,time,os,pwd,shutil,urllib.request
base=pathlib.Path('/opt/bobtv/live-subtitles');backup=base/'backups'/('client-'+str(int(time.time())));backup.mkdir(parents=True)
with tarfile.open('/tmp/bobtv-client-clock.tar') as a:
 m=json.load(a.extractfile('receipt.json'));release=base/'releases'/m['commit'];release.mkdir(exist_ok=True);a.extractall(release,filter='data')
for p in release.iterdir():p.chmod(0o644)
release.chmod(0o755)
subprocess.run(['/opt/bobtv/subtitles-venv/bin/python','-m','unittest','discover','-s',str(release),'-p','test_*py'],check=True)
u=pwd.getpwnam('bobtv');root=pathlib.Path('/var/lib/bobtv/client-subtitles');root.mkdir(exist_ok=True);os.chown(root,u.pw_uid,u.pw_gid);root.chmod(0o700)
unit=pathlib.Path('/etc/systemd/system/bobtv-client-subtitles.service');snippet=pathlib.Path('/etc/nginx/snippets/bobtv-client-subtitles.conf');nginx=pathlib.Path('/etc/nginx/conf.d/bobtv.conf');link=base/'current-client'
original=nginx.read_bytes();(backup/'bobtv.conf').write_bytes(original);oldlink=str(link.resolve()) if link.exists() else None
for p in [unit,snippet]:
 if p.exists():shutil.copy2(p,backup/p.name)
try:
 nxt=base/'next-client'
 if nxt.is_symlink():nxt.unlink()
 nxt.symlink_to(release,target_is_directory=True);os.replace(nxt,link)
 shutil.copy2(release/'bobtv-client-subtitles.service',unit);shutil.copy2(release/'bobtv-client-subtitles.conf',snippet)
 text=original.decode();include='    include snippets/bobtv-client-subtitles.conf;'
 if include not in text:
  anchor='    include snippets/bobtv-live-subtitles.conf;';assert text.count(anchor)==1;nginx.write_text(text.replace(anchor,anchor+'\n'+include))
 subprocess.run(['systemctl','daemon-reload'],check=True);subprocess.run(['systemctl','restart','bobtv-client-subtitles'],check=True)
 for _ in range(45):
  try:
   with urllib.request.urlopen('http://127.0.0.1:8923/health',timeout=2) as r:d=json.load(r);assert d['clientOnly'] and not d['engineRunning']
   break
  except (OSError,AssertionError):time.sleep(1)
 else:raise RuntimeError('client_clock_health_failed')
 subprocess.run(['nginx','-t'],check=True);subprocess.run(['systemctl','reload','nginx'],check=True)
 subprocess.run(['systemctl','enable','bobtv-client-subtitles'],check=True)
 receipt=dict(sourceCommit=m['commit'],backup=str(backup),deployedAtUtc=time.time(),files=m['files'],health=d,publicPath='/api/v1/subtitles/client/')
 (backup/'receipt.json').write_text(json.dumps(receipt,indent=2));print(json.dumps(receipt))
except BaseException:
 nginx.write_bytes(original)
 for p in [unit,snippet]:
  if (backup/p.name).exists():shutil.copy2(backup/p.name,p)
  elif p.exists():p.unlink()
 if link.is_symlink():link.unlink()
 if oldlink:link.symlink_to(oldlink,target_is_directory=True)
 subprocess.run(['systemctl','daemon-reload']);subprocess.run(['systemctl','restart' if oldlink else 'stop','bobtv-client-subtitles']);subprocess.run(['nginx','-t'],check=True);subprocess.run(['systemctl','reload','nginx']);raise
'''
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--key',required=True);p.add_argument('--host',default='root@ccnode.briconbric.com');a=p.parse_args()
 commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
 files=[*FILES,'bobtv-client-subtitles.service','bobtv-client-subtitles.conf']
 with tempfile.TemporaryDirectory() as d:
  d=Path(d);hashes={}
  for f in files:
   content=(ROOT/'tools/live_subtitles'/f).read_bytes();assert content==subprocess.check_output(['git','show',commit+':tools/live_subtitles/'+f],cwd=ROOT);hashes[f]=hashlib.sha256(content).hexdigest()
  (d/'receipt.json').write_text(json.dumps(dict(commit=commit,files=hashes)))
  with tarfile.open(d/'runtime.tar','w') as archive:
   for f in files:archive.add(ROOT/'tools/live_subtitles'/f,arcname=f)
   archive.add(d/'receipt.json',arcname='receipt.json')
  subprocess.run(['scp','-4','-q','-i',a.key,str(d/'runtime.tar'),a.host+':/tmp/bobtv-client-clock.tar'],check=True)
  subprocess.run(['ssh','-4','-oBatchMode=yes','-oConnectTimeout=10','-i',a.key,a.host,'python3 -'],input=REMOTE,text=True,check=True)
