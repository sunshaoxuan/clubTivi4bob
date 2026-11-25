#!/usr/bin/env python3
"""Deploy only the backwards-compatible casting diagnostic field allowlist."""
import hashlib
import json
import shlex
import subprocess
from pathlib import Path
from deploy_resource_relay import ROOT, ssh

INSTALL = r'''
import base64, hashlib, json, os, shutil, subprocess, sys, time
from pathlib import Path
value=json.load(sys.stdin)
root=Path(value['root']); target=root/'diagnostic_store.py'
if hashlib.sha256(target.read_bytes().rstrip()).hexdigest()!=value['before']:
    raise SystemExit('Live diagnostic schema changed; inspect before deployment')
new=base64.b64decode(value['body'])
compile(new, str(target), 'exec')
backup=root/'backups'/('cast-diagnostics-'+time.strftime('%Y%m%dT%H%M%SZ',time.gmtime()))
backup.mkdir(parents=True,exist_ok=False)
shutil.copy2(target,backup/target.name)
temporary=target.with_name('.cast-diagnostic-store.tmp')
temporary.write_bytes(new); shutil.copystat(target,temporary)
stat=target.stat(); os.chown(temporary,stat.st_uid,stat.st_gid)
os.replace(temporary,target)
try:
    subprocess.run([value['python'],'-c','import diagnostic_store,diagnostics_api'],cwd=root,check=True)
    subprocess.run(['systemctl','restart',value['service']],check=True)
    subprocess.run(['systemctl','is-active','--quiet',value['service']],check=True)
except BaseException:
    shutil.copy2(backup/target.name,target)
    subprocess.run(['systemctl','restart',value['service']],check=False)
    raise
print(json.dumps({'service':value['service'],'state':'active','backup':str(backup),
    'sha256':hashlib.sha256(target.read_bytes()).hexdigest()}))
'''


def main():
    import base64
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-ref', default='HEAD')
    args = parser.parse_args()
    name = 'website/diagnostic_store.py'
    before = hashlib.sha256(subprocess.check_output(['git', 'show', args.baseline_ref + ':' + name], cwd=ROOT).rstrip()).hexdigest()
    body = base64.b64encode((ROOT / name).read_bytes()).decode()
    for host, directory, service in [
        ('ccnode.briconbric.com', '/opt/bobtv/site', 'bobtv.service'),
        ('cndrp.com', '/opt/bobtv-relay', 'bobtv-resource-relay.service'),
    ]:
        runtime = '/opt/bobtv/venv/bin/python' if 'ccnode' in host else directory + '/venv/bin/python'
        print(ssh(host, 'python3 -c ' + shlex.quote(INSTALL), json.dumps({
            'root': directory, 'service': service, 'python': runtime,
            'before': before, 'body': body})).strip())


if __name__ == '__main__':
    main()
