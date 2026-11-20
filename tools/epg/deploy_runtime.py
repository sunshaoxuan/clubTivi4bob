"""Deploy the frozen runtime overlay over a hash-checked production baseline.

Usage: python deploy_runtime.py --ssh-key PATH --host root@HOST
Existing timer states are restored on success or failure. No client is restarted.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT=Path(__file__).resolve().parents[2]
FILES=['epg_ingest.py','epg_store.py','epg_channel_search.py','epg_auto_search.py',
       'epg_auto_search_worker.py','epg_rakuten.py','epg_pluto.py','epg_programme_probe.py','epg_sources.json',
       'epg_research_rounds.py','broadcast_market.py','broadcast_market_bindings.json','market_review_admin.py']
REMOTE=r'''
import hashlib,json,os,pathlib,pwd,shutil,sqlite3,subprocess,tarfile,time
from datetime import datetime,timezone
stage=pathlib.Path('/opt/bobtv/epg-staging')/('deploy-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'));stage.mkdir(mode=0o700)
with tarfile.open('/tmp/bobtv-epg-runtime.tar.gz') as archive:archive.extractall(stage,filter='data')
meta=json.loads((stage/'deployment.json').read_text());site=pathlib.Path('/opt/bobtv/site');data=pathlib.Path('/var/lib/bobtv')
for name,expected in meta['baseline'].items():
    assert hashlib.sha256((site/name).read_bytes()).hexdigest()==expected,'production source drift: '+name
for name in meta['newFiles']:assert not (site/name).exists(),'new module already exists: '+name
units=['bobtv-epg-'+s for s in ['validator','schedules','publisher','discovery','source-discovery']]
active=[u+'.timer' for u in units if subprocess.run(['systemctl','is-active','--quiet',u+'.timer']).returncode==0]
backup=pathlib.Path('/opt/bobtv/backups')/stage.name;backup.mkdir(parents=True,mode=0o700)
try:
    subprocess.run(['systemctl','stop',*active],check=True)
    deadline=time.monotonic()+180
    while any(subprocess.run(['systemctl','is-active','--quiet',u+'.service']).returncode==0 for u in units):
        assert time.monotonic()<deadline,'active worker did not finish'
        time.sleep(2)
    source=sqlite3.connect('file:'+str(data/'epg/epg.sqlite3')+'?mode=ro',uri=True);dest=sqlite3.connect(backup/'epg.sqlite3');source.backup(dest);dest.close();source.close()
    for name in meta['files']:
        if (site/name).exists():shutil.copy2(site/name,backup/name)
    drop=pathlib.Path('/etc/systemd/system/bobtv-epg-source-discovery.service.d/20-channel-first.conf')
    shutil.copy2(drop,backup/'20-channel-first.conf')
    owner=pwd.getpwnam('bobtv')
    for name in meta['files']:
        temp=site/(name+'.deploy-tmp');shutil.copy2(stage/name,temp);os.chown(temp,owner.pw_uid,owner.pw_gid);temp.chmod(0o644);os.replace(temp,site/name)
    subprocess.run(['/opt/bobtv/venv/bin/python','-m','py_compile',*[str(site/n) for n in meta['files'] if n.endswith('.py')]],check=True)
    shutil.copy2(stage/'20-channel-first.conf',drop);drop.chmod(0o644)
    subprocess.run(['systemctl','daemon-reload'],check=True)
    receipt={'sourceCommit':meta['sourceCommit'],'deployedAtUtc':int(time.time()),'backup':str(backup),'files':{n:hashlib.sha256((site/n).read_bytes()).hexdigest() for n in meta['files']},'timersRestored':active}
    (backup/'receipt.json').write_text(json.dumps(receipt,indent=2));print(json.dumps(receipt),flush=True)
except BaseException:
    for name in meta['files']:
        if (backup/name).exists():shutil.copy2(backup/name,site/name)
        elif name in meta['newFiles'] and (site/name).exists():(site/name).unlink()
    if (backup/'20-channel-first.conf').exists():shutil.copy2(backup/'20-channel-first.conf','/etc/systemd/system/bobtv-epg-source-discovery.service.d/20-channel-first.conf')
    subprocess.run(['systemctl','daemon-reload']);raise
finally:
    subprocess.run(['systemctl','start',*active],check=True)
'''

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--ssh-key',required=True);p.add_argument('--host',required=True);p.add_argument('--baseline',type=Path);a=p.parse_args()
    commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    # Other client work may proceed concurrently. Every deployed byte must
    # match this exact committed source, including the systemd override.
    for n in FILES:
        source=ROOT/'website'/n
        if not source.exists():source=ROOT/'production/catalog'/n
        committed=subprocess.check_output(['git','show',commit+':'+source.relative_to(ROOT).as_posix()],cwd=ROOT)
        assert source.read_bytes()==committed,'commit deployed source first: '+n
    baseline=json.loads((a.baseline or ROOT/'production/epg/production-baseline.json').read_text())['files']
    baseline={n:(v['sha256'] if isinstance(v,dict) else v) for n,v in baseline.items()}
    meta={'sourceCommit':commit,'files':FILES,'baseline':{n:baseline[n] for n in FILES if n in baseline},'newFiles':[n for n in FILES if n not in baseline]}
    with tempfile.TemporaryDirectory() as d:
        d=Path(d);(d/'deployment.json').write_text(json.dumps(meta))
        with tarfile.open(d/'runtime.tar.gz','w:gz') as t:
            for n in FILES:
                source=ROOT/'website'/n
                if not source.exists():source=ROOT/'production/catalog'/n
                t.add(source,arcname=n)
            t.add(ROOT/'website/deploy/bobtv-epg-source-discovery.service.d/20-channel-first.conf',arcname='20-channel-first.conf');t.add(d/'deployment.json',arcname='deployment.json')
        subprocess.run(['scp','-q','-i',a.ssh_key,str(d/'runtime.tar.gz'),a.host+':/tmp/bobtv-epg-runtime.tar.gz'],check=True)
    subprocess.run(['ssh','-i',a.ssh_key,'-o','BatchMode=yes',a.host,'python3','-'],input=REMOTE,text=True,check=True)
if __name__=='__main__':main()
