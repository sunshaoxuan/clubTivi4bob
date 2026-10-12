"""Update only resource scripts/tags, retaining deployed styles and locales."""
import json
import shlex
import subprocess
from deploy_resource_relay import ROOT, ssh, upload

INSTALL = r'''
import json,re,shutil,subprocess,sys,time
from pathlib import Path
stage=Path(json.load(sys.stdin)['stage']);site=Path('/opt/bobtv/site')
backup=Path('/opt/bobtv/backups')/('resource-web-'+time.strftime('%Y%m%dT%H%M%SZ',time.gmtime()))
backup.mkdir(parents=True)
for name in ['resources.js','downloads.js','diagnostics.js']:
    target=site/'assets'/name
    if target.exists():shutil.copy2(target,backup/name)
    shutil.copy2(stage/name,target)
for suffix,name,version in [('templates/downloads.html','downloads',10),
    ('templates/diagnostics.html','diagnostics',3),('downloads.html','downloads',10),
    ('diagnostics.html','diagnostics',3)]:
    target=site/suffix
    if not target.exists() and '/' not in suffix: continue
    text=target.read_text()
    shutil.copy2(target,backup/suffix.replace('/','-'))
    pattern=r'<script src="/assets/'+name+r'\.js\?v=\d+" defer></script>'
    if 'resources.js?v=1' not in text:
        replacement='<script src="/assets/resources.js?v=1" defer></script><script src="/assets/'+name+'.js?v='+str(version)+'" defer></script>'
        text,count=re.subn(pattern,replacement,text)
        if count!=1:raise ValueError('Unexpected deployed resource script tag')
        target.write_text(text)
subprocess.run(['systemctl','restart','bobtv.service'],check=True)
subprocess.run(['systemctl','is-active','--quiet','bobtv.service'],check=True)
print(json.dumps({'websiteBackup':str(backup),'localizedStylePreserved':True}))
'''

def main():
    host='ccnode.briconbric.com'
    stage=ssh(host,'mktemp -d /opt/bobtv-resource-web-XXXXXX').strip()
    upload(host,stage,[ROOT/'website/assets'/name for name in ['resources.js','downloads.js','diagnostics.js']])
    print(ssh(host,'python3 -c '+shlex.quote(INSTALL),json.dumps({'stage':stage})))

if __name__=='__main__':main()
