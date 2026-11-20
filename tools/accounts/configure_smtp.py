"""Validate encrypted SMTP and activate BobTV mail config without restarting.

Reads a private JSON file. Secrets travel over authenticated SSH stdin only.
No test message is sent and no mailbox credentials are changed.
"""
import argparse
import json
import shlex
import smtplib
import ssl
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from deploy_resource_relay import ssh

UPDATE = r'''
import grp,json,os,secrets,sys
from pathlib import Path
incoming=json.load(sys.stdin)
allowed={'smtp_host','smtp_port','smtp_user','smtp_from','smtp_password'}
if set(incoming)!=allowed:raise ValueError('Unexpected SMTP fields')
path=Path('/etc/bobtv/accounts.json');values=json.loads(path.read_text())
values.update(incoming)
temporary=path.with_name('.accounts-smtp-'+secrets.token_hex(8))
fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
try:
 with os.fdopen(fd,'w') as output:json.dump(values,output)
 os.chown(temporary,0,grp.getgrnam('bobtv').gr_gid);os.chmod(temporary,0o640);os.replace(temporary,path)
finally:
 temporary.unlink(missing_ok=True)
print(json.dumps({'smtpConfigured':bool(values.get('smtp_password')),'restartRequired':False}))
'''


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--credentials',type=Path,default=Path.home()/'.config/bobtv/accounts-secrets.json')
    parser.add_argument('--receipt',type=Path)
    args=parser.parse_args()
    config=json.loads(args.credentials.read_text())
    fields={key:config[key] for key in ['smtp_host','smtp_port','smtp_user','smtp_from','smtp_password']}
    if fields['smtp_host']!='mail.briconbric.com' or fields['smtp_port']!=465:
        raise ValueError('Expected the user-selected TLS SMTP service')
    with smtplib.SMTP_SSL(fields['smtp_host'],465,context=ssl.create_default_context(),timeout=15) as smtp:
        smtp.login(fields['smtp_user'],fields['smtp_password'])
    result=json.loads(ssh('ccnode.briconbric.com','python3 -c '+shlex.quote(UPDATE),json.dumps(fields)))
    result.update(tlsLoginVerified=True,mailSent=False)
    if args.receipt:
        args.receipt.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))


if __name__=='__main__':
    try:main()
    except Exception as exc:
        # Never print SMTP responses or config contents on failure.
        print('SMTP setup failed: '+type(exc).__name__,file=sys.stderr)
        sys.exit(1)
