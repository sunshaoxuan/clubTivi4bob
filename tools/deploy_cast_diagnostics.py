#!/usr/bin/env python3
"""Deploy backwards-compatible casting diagnostic metadata and gzip support."""
import base64
import hashlib
import json
import shlex
import subprocess
from deploy_resource_relay import ROOT, ssh

INSTALL = r'''
import base64, hashlib, json, os, shutil, subprocess, sys, time
from pathlib import Path
value=json.load(sys.stdin); root=Path(value['root'])
for name, item in value['files'].items():
    target=root/name
    if hashlib.sha256(target.read_bytes().rstrip()).hexdigest()!=item['before']:
        raise SystemExit('Live diagnostic module changed: '+name)
    compile(base64.b64decode(item['body']), str(target), 'exec')
backup=root/'backups'/('cast-diagnostics-'+time.strftime('%Y%m%dT%H%M%SZ',time.gmtime()))
backup.mkdir(parents=True,exist_ok=False)
for name in value['files']:
    shutil.copy2(root/name,backup/name)
try:
    for name, item in value['files'].items():
        target=root/name; temporary=target.with_name('.'+name+'.tmp')
        temporary.write_bytes(base64.b64decode(item['body'])); shutil.copystat(target,temporary)
        stat=target.stat(); os.chown(temporary,stat.st_uid,stat.st_gid)
        os.replace(temporary,target)
    subprocess.run([value['python'],'-c','import diagnostic_store,diagnostics_api'],cwd=root,check=True)
    subprocess.run(['systemctl','restart',value['service']],check=True)
    subprocess.run(['systemctl','is-active','--quiet',value['service']],check=True)
except BaseException:
    for name in value['files']:
        shutil.copy2(backup/name,root/name)
    subprocess.run(['systemctl','restart',value['service']],check=False)
    raise
print(json.dumps({'service':value['service'],'state':'active','backup':str(backup),
    'files':{name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in value['files']}}))
'''


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-ref', default='HEAD')
    args = parser.parse_args()
    for host, directory, service in [
        ('ccnode.briconbric.com', '/opt/bobtv/site', 'bobtv.service'),
        ('cndrp.com', '/opt/bobtv-relay', 'bobtv-resource-relay.service'),
    ]:
        names = ['diagnostic_store.py', 'diagnostics_api.py']
        if 'cndrp' in host:
            names.append('diagnostic_relay_worker.py')
        files = {}
        for name in names:
            relative = 'website/' + name
            before = subprocess.check_output(['git', 'show', args.baseline_ref + ':' + relative], cwd=ROOT)
            files[name] = {'before': hashlib.sha256(before.rstrip()).hexdigest(),
                           'body': base64.b64encode((ROOT / relative).read_bytes()).decode()}
        runtime = '/opt/bobtv/venv/bin/python' if 'ccnode' in host else directory + '/venv/bin/python'
        print(ssh(host, 'python3 -c ' + shlex.quote(INSTALL), json.dumps({
            'root': directory, 'service': service, 'python': runtime, 'files': files})).strip())


if __name__ == '__main__':
    main()
