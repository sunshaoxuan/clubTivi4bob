"""Install the committed pilot as an isolated service, retaining rollback files."""
import argparse
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FILES = ['live_media.py', 'subtitle_catalog.py', 'live_engine.py', 'service.py', 'test_live_service.py',
         'bobtv-live-subtitles.service', 'bobtv-live-subtitles.conf', 'requirements.txt']

REMOTE = r'''
import pathlib,tarfile,subprocess,pwd,os,shutil,json,time,hashlib,urllib.request
base=pathlib.Path('/opt/bobtv/live-subtitles');meta=None
with tarfile.open('/tmp/bobtv-live-subtitles.tar') as archive:
 meta=json.load(archive.extractfile('receipt.json'))
 release=base/'releases'/meta['commit'];release.mkdir(parents=True,exist_ok=True)
 archive.extractall(release,filter='data')
u=pwd.getpwnam('bobtv')
for file in release.iterdir():file.chmod(0o644)
release.chmod(0o755)
data=pathlib.Path('/var/lib/bobtv/live-subtitles');data.mkdir(exist_ok=True);os.chown(data,u.pw_uid,u.pw_gid);data.chmod(0o700)
preflight="""import av,tempfile,wave,importlib.metadata
from pathlib import Path
assert av.__version__=='15.1.0'
assert importlib.metadata.version('faster-whisper')=='1.2.1'
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'silence.wav'
 with wave.open(str(p),'wb') as w:
  w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000);w.writeframes(b'\\0'*64000)
 with av.open(str(p),mode='r',metadata_errors='ignore') as c:assert c.streams.audio[0].sample_rate==16000
"""
subprocess.run(['/opt/bobtv/subtitles-venv/bin/python','-c',preflight],check=True)
subprocess.run(['/opt/bobtv/subtitles-venv/bin/python','-m','unittest','discover','-s',str(release),'-p','test_live_service.py'],check=True)
backup=base/'backups'/str(int(time.time()));backup.mkdir(parents=True)
nginx=pathlib.Path('/etc/nginx/conf.d/bobtv.conf');original=nginx.read_bytes();(backup/'bobtv.conf').write_bytes(original)
unit=pathlib.Path('/etc/systemd/system/bobtv-live-subtitles.service');snippet=pathlib.Path('/etc/nginx/snippets/bobtv-live-subtitles.conf');current=base/'current'
old_link=str(current.resolve()) if current.exists() else None
for p in [unit,snippet]:
 if p.exists():shutil.copy2(p,backup/p.name)
try:
 temporary=base/'next'
 if temporary.is_symlink():temporary.unlink()
 temporary.symlink_to(release,target_is_directory=True);os.replace(temporary,current)
 shutil.copy2(release/unit.name,unit);shutil.copy2(release/snippet.name,snippet)
 subprocess.run(['systemctl','daemon-reload'],check=True);subprocess.run(['systemctl','restart','bobtv-live-subtitles'],check=True)
 for _ in range(60):
  try:
   with urllib.request.urlopen('http://127.0.0.1:8921/health',timeout=2) as r:assert r.status==200
   break
  except (OSError,AssertionError):time.sleep(1)
 else:raise RuntimeError('pilot_health_failed')
 text=original.decode();include='    include snippets/bobtv-live-subtitles.conf;'
 if include not in text:
  marker='    include snippets/bobtv-epg-api.conf;'
  assert text.count(marker)==1,'nginx_anchor_changed'
  assert nginx.read_bytes()==original,'nginx_changed_during_deployment'
  nginx.write_text(text.replace(marker,marker+'\n'+include))
 subprocess.run(['nginx','-t'],check=True);subprocess.run(['systemctl','reload','nginx'],check=True)
 subprocess.run(['systemctl','enable','bobtv-live-subtitles'],check=True)
 receipt={'sourceCommit':meta['commit'],'backup':str(backup),'deployedAtUtc':int(time.time()),'files':meta['files'],'publicPath':'/api/v1/subtitles/','pilot':'rakuten-uk-6065'}
 (backup/'receipt.json').write_text(json.dumps(receipt,indent=2));print(json.dumps(receipt))
except BaseException:
 nginx.write_bytes(original)
 for p in [unit,snippet]:
  if (backup/p.name).exists():shutil.copy2(backup/p.name,p)
  elif p.exists():p.unlink()
 if old_link:
  current.unlink();current.symlink_to(old_link,target_is_directory=True)
 subprocess.run(['systemctl','daemon-reload']);subprocess.run(['systemctl','stop' if not old_link else 'restart','bobtv-live-subtitles'])
 subprocess.run(['nginx','-t'],check=True);subprocess.run(['systemctl','reload','nginx']);raise
'''


def main():
    p=argparse.ArgumentParser();p.add_argument('--key',required=True);p.add_argument('--host',default='root@ccnode.briconbric.com');a=p.parse_args()
    commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    import hashlib
    hashes={}
    for name in FILES:
        file=ROOT/'tools/live_subtitles'/name
        assert file.read_bytes()==subprocess.check_output(['git','show',commit+':'+str(file.relative_to(ROOT))],cwd=ROOT)
        hashes[name]=hashlib.sha256(file.read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory() as folder:
        folder=Path(folder);(folder/'receipt.json').write_text(json.dumps(dict(commit=commit,files=hashes)))
        with tarfile.open(folder/'runtime.tar','w') as archive:
            for name in FILES:archive.add(ROOT/'tools/live_subtitles'/name,arcname=name)
            archive.add(folder/'receipt.json',arcname='receipt.json')
        subprocess.run(['scp','-q','-i',a.key,str(folder/'runtime.tar'),a.host+':/tmp/bobtv-live-subtitles.tar'],check=True)
    subprocess.run(['ssh','-i',a.key,a.host,'python3','-'],input=REMOTE,text=True,check=True)


if __name__=='__main__':main()
