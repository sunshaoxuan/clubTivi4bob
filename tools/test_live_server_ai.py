"""Admin-side readiness check using existing credentials, never printing them."""
import json
import subprocess

program = '''import json,sys
sys.path.insert(0,'/opt/bobtv/site')
from server_worker import config,ai
from urllib.parse import urlsplit
settings=config()
assert all(settings.get(k) for k in ('baseUrl','apiKey','model'))
assert urlsplit(settings['baseUrl']).scheme=='https'
result=ai({'check':'BobTV release readiness'},'Reply with {"ok":true}.',settings)
assert result.get('ok') is True
print(json.dumps({'configured':True,'https':True,'structuredResponse':True}))
'''
ssh = ['ssh','-i','/Users/shou/Desktop/Secure/sunsxaws.pem','-o','ConnectTimeout=15',
       'root@ccnode.briconbric.com',
       'cd /opt/bobtv/site && runuser -u bobtv -- env BOBTV_DATA_DIR=/var/lib/bobtv /opt/bobtv/venv/bin/python -']
result = subprocess.run(ssh, input=program, text=True, capture_output=True)
if result.returncode:
    # Tracebacks can contain upstream metadata. Return only a safe outcome.
    raise SystemExit('Server AI readiness check failed; inspect server error codes locally')
print(json.dumps(json.loads(result.stdout)))
