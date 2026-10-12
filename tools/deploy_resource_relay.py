"""Deploy a scoped relay and origin trust, preserving live mail/site services.

Run locally with already authorized SSH key. Secrets travel through stdin and
root-owned files only. No client packages or running desktop apps are replaced.
"""
import json
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
KEY = '/Users/shou/Desktop/Secure/sunsxaws.pem'


def ssh(host, command, data=None):
    result = subprocess.run(['ssh', '-i', KEY, '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=10', 'root@' + host, command],
        input=data, text=not isinstance(data, bytes), capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{host}: {result.stderr[-3000:]} {result.stdout[-3000:]}')
    return result.stdout.decode() if isinstance(result.stdout, bytes) else result.stdout


def upload(host, stage, files):
    command = ['tar', '-cf', '-']
    for source in files:
        command.extend(['-C', str(source.parent), source.name])
    archive = subprocess.run(command, check=True, capture_output=True).stdout
    # One authenticated transfer avoids rate-limited repeated SFTP sessions.
    ssh(host, 'tar -xf - -C ' + __import__('shlex').quote(stage), archive)


ORIGIN_INSTALL = r'''
import grp,json,os,shutil,subprocess,sys,tempfile,time
from pathlib import Path
payload=json.load(sys.stdin); stage=Path(payload['stage']); secret=payload['secret']
site=Path('/opt/bobtv/site'); config=Path('/etc/bobtv/resource-relays.json')
backup=Path('/opt/bobtv/backups')/('resource-relay-'+time.strftime('%Y%m%dT%H%M%SZ',time.gmtime()))
backup.mkdir(parents=True)
for path in [site/'app.py', site/'resource_nodes.py', config]:
    if path.exists(): shutil.copy2(path,backup/path.name)
text=(site/'app.py').read_text()
anchor='app.include_router(egress_router)\n'
addition=(stage/'app.py').read_text()
start=addition.index("@app.middleware('http')")
end=addition.index('app.mount("/assets"',start)
if 'from resource_nodes import' not in text:
    if text.count('from egress_gateway import router as egress_router')!=1 or text.count(anchor)!=1:
        raise ValueError('Live origin router anchors changed')
    text=text.replace('from egress_gateway import router as egress_router',
        'from egress_gateway import router as egress_router\nfrom resource_nodes import router as resource_node_router, trusted_client')
    text=text.replace(anchor,anchor+'app.include_router(resource_node_router)\n\n'+addition[start:end])
values=json.loads(config.read_text()) if config.exists() else {'nodes':{}}
values.setdefault('nodes',{})['cndrp']={'enabled':True,'addresses':['121.43.197.117'],'secret':secret}
config.parent.mkdir(exist_ok=True)
config.write_text(json.dumps(values)); os.chmod(config,0o640); os.chown(config,0,grp.getgrnam('bobtv').gr_gid)
shutil.copy2(stage/'resource_nodes.py',site/'resource_nodes.py')
(site/'app.py').write_text(text)
subprocess.run(['/opt/bobtv/venv/bin/python','-c','import app'],cwd=site,check=True)
subprocess.run(['systemctl','restart','bobtv.service'],check=True)
subprocess.run(['systemctl','is-active','--quiet','bobtv.service'],check=True)
print(json.dumps({'originBackup':str(backup),'originService':'active'}))
'''

RELAY_INSTALL = r'''
import json,os,pwd,shutil,subprocess,sys,time
from pathlib import Path
payload=json.load(sys.stdin);stage=Path(payload['stage']);secret=payload['secret']
root=Path('/opt/bobtv-relay'); root.mkdir(exist_ok=True)
try: user=pwd.getpwnam('bobtv-relay')
except KeyError:
    subprocess.run(['useradd','--system','--no-create-home','--shell','/usr/sbin/nologin','bobtv-relay'],check=True)
    user=pwd.getpwnam('bobtv-relay')
backup=root/'backups'/time.strftime('%Y%m%dT%H%M%SZ',time.gmtime());backup.mkdir(parents=True)
cache=Path('/var/cache/bobtv-relay');cache.mkdir(exist_ok=True);web=pwd.getpwnam('www-data');os.chown(cache,web.pw_uid,web.pw_gid)
conf=Path('/etc/bobtv-relay');conf.mkdir(exist_ok=True);os.chmod(conf,0o750);os.chown(conf,0,user.pw_gid)
env=conf/'relay.env'
if env.exists():shutil.copy2(env,backup/'relay.env')
env.write_text('BOBTV_RELAY_SECRET='+secret+'\nBOBTV_RELAY_ORIGIN_IP=203.24.89.50\n');os.chmod(env,0o640);os.chown(env,0,user.pw_gid)
for name in ['resource_relay.py','resource_nodes.py']:
    target=root/name
    if target.exists():shutil.copy2(target,backup/name)
    shutil.copy2(stage/name,target)
if not (root/'venv/bin/pip').exists():
    subprocess.run(['python3','-m','venv','--without-pip',str(root/'venv')],check=True)
if not list(stage.glob('*.whl')):raise ValueError('Verified offline runtime wheels required')
subprocess.run(['python3','-m','pip','--python',str(root/'venv/bin/python'),'install',
    '--quiet','--no-index','--find-links',str(stage),'pip','fastapi>=0.115,<1',
    'uvicorn>=0.30,<1','httpx>=0.27,<1'],check=True)
subprocess.run([str(root/'venv/bin/python'),'-c','import resource_relay'],cwd=root,check=True)
targets={Path('/etc/systemd/system/bobtv-resource-relay.service'):'bobtv-resource-relay.service',
    Path('/etc/nginx/conf.d/bobtv-resource-cache.conf'):'bobtv-resource-relay-cache.conf',
    Path('/etc/nginx/snippets/bobtv-resource-location.conf'):'bobtv-resource-relay-location.conf'}
for target, source in targets.items():
    if target.exists():shutil.copy2(target,backup/target.name)
    shutil.copy2(stage/source,target)
custom=Path('/home/user-data/www/cndrp.com.conf');local=Path('/etc/nginx/conf.d/local.conf')
for file in [custom,local]:
    if file.exists():shutil.copy2(file,backup/file.name)
line='include /etc/nginx/snippets/bobtv-resource-location.conf;'
text=custom.read_text() if custom.exists() else ''
if line not in text: custom.write_text(text+'\n'+line+'\n')
text=local.read_text()
needle='server_name cndrp.com;'
positions=[i for i in range(len(text)) if text.startswith(needle,i)]
if len(positions)!=2:raise ValueError('Unexpected cndrp mail-in-a-box server layout')
start=text.rfind('server {',0,positions[1]);end=text.find('\nserver {',positions[1])
if end<0:end=len(text)
section=text[start:end]
if 'include /home/user-data/www/cndrp.com.conf;' not in section:
    section=section.replace(needle,needle+'\n\tinclude /home/user-data/www/cndrp.com.conf;',1)
    local.write_text(text[:start]+section+text[end:])
subprocess.run(['nginx','-t'],check=True)
subprocess.run(['systemctl','daemon-reload'],check=True)
subprocess.run(['systemctl','enable','bobtv-resource-relay.service'],check=True)
subprocess.run(['systemctl','restart','bobtv-resource-relay.service'],check=True)
subprocess.run(['systemctl','reload','nginx'],check=True)
subprocess.run(['systemctl','is-active','--quiet','bobtv-resource-relay.service'],check=True)
print(json.dumps({'relayBackup':str(backup),'relayService':'active','cacheLimitGiB':8,'mailConfigPreserved':True}))
'''


def main():
    stages = {}
    wheels = list((ROOT.parent.parent/'outputs/BobTV-resource-relay-wheels').glob('*.whl'))
    if not wheels: raise RuntimeError('Prepare Linux Python 3.10 wheels before deployment')
    existing = ssh('ccnode.briconbric.com',
        'python3 -c ' + __import__('shlex').quote(
            "from pathlib import Path; import json; p=Path('/etc/bobtv/resource-relays.json'); "
            "print(json.loads(p.read_text()).get('nodes',{}).get('cndrp',{}).get('secret','') if p.exists() else '')")).strip()
    secret = existing if len(existing) == 64 else secrets.token_hex(32)
    relay_only = '--relay-only' in sys.argv
    if relay_only and len(existing) != 64: raise RuntimeError('Origin trust must be deployed first')
    for host in (['cndrp.com'] if relay_only else ['ccnode.briconbric.com', 'cndrp.com']):
        stages[host] = ssh(host, 'mktemp -d /opt/bobtv-resource-stage-XXXXXX').strip()
    for host, stage in stages.items():
        upload(host, stage, [ROOT/'website/resource_nodes.py', ROOT/'website/resource_relay.py',
            ROOT/'website/app.py', *[ROOT/'website/deploy'/name for name in [
                'bobtv-resource-relay.service', 'bobtv-resource-relay-cache.conf',
                'bobtv-resource-relay-location.conf']], *wheels])
    for host, script in [('ccnode.briconbric.com', ORIGIN_INSTALL), ('cndrp.com', RELAY_INSTALL)]:
        if host not in stages: continue
        # Server-owned secrets are never command-line arguments or output.
        cmd = 'python3 -c ' + __import__('shlex').quote(script)
        print(ssh(host, cmd, json.dumps({'stage':stages[host], 'secret':secret})), flush=True)


if __name__ == '__main__': main()
