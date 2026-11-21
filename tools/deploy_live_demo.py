"""Install the isolated public demo without replacing the website or EPG worker."""
import argparse
import json
from pathlib import Path
import shlex

from deploy_resource_relay import ROOT, ssh

INSTALL = r"""
import json,os,pwd,shutil,subprocess,time,urllib.request
from pathlib import Path
source=Path(STAGE)
app=Path('/opt/bobtv/live-demo');app.mkdir(parents=True,exist_ok=True)
work=Path('/var/lib/bobtv-live-demo');work.mkdir(exist_ok=True)
user=pwd.getpwnam('bobtv');os.chown(work,user.pw_uid,user.pw_gid)
unit=Path('/etc/systemd/system/bobtv-live-demo.service')
snippet=Path('/etc/nginx/snippets/bobtv-live-demo.conf')
nginx=Path('/etc/nginx/conf.d/bobtv.conf')
files=[app/'serve.py',unit,snippet,nginx]
backup=Path('/opt/bobtv/backups')/('live-demo-'+str(int(time.time())))
backup.mkdir(mode=0o700)
existed=[p.exists() for p in files]
for n,p in enumerate(files):
 if p.exists():shutil.copy2(p,backup/str(n))
try:
 shutil.copy2(source,app/'serve.py')
 os.chmod(app/'serve.py',0o644)
 unit.write_text('''[Unit]
Description=BobTV open HLS demo
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=bobtv
Group=bobtv
ExecStart=/usr/bin/python3 /opt/bobtv/live-demo/serve.py --work-dir /var/lib/bobtv-live-demo --bind 127.0.0.1 --port 18767 --public-base https://bobtv.briconbric.com/api/v1/demo
Restart=on-failure
RestartSec=10
TimeoutStopSec=30
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/bobtv-live-demo
MemoryMax=768M
CPUQuota=100%
TasksMax=80
UMask=0027
[Install]
WantedBy=multi-user.target
''')
 snippet.write_text('''location ^~ /api/v1/demo/ {
    proxy_pass http://127.0.0.1:18767/;
    proxy_set_header Host $host;
    proxy_connect_timeout 3s;
    proxy_read_timeout 15s;
    proxy_buffering off;
    proxy_hide_header Cache-Control;
    add_header Cache-Control "no-store" always;
}
''')
 text=nginx.read_text();anchor='    include snippets/bobtv-client-subtitles.conf;'
 if 'include snippets/bobtv-live-demo.conf;' not in text:
  if text.count(anchor)!=1:raise ValueError('Nginx include anchor changed')
  nginx.write_text(text.replace(anchor,anchor+'\n    include snippets/bobtv-live-demo.conf;'))
 subprocess.run(['nginx','-t'],check=True,capture_output=True)
 subprocess.run(['systemctl','daemon-reload'],check=True)
 subprocess.run(['systemctl','enable','--now','bobtv-live-demo'],check=True,capture_output=True)
 for attempt in range(100):
  try:
   with urllib.request.urlopen('http://127.0.0.1:18767/hls/signal/index.m3u8',timeout=2) as r:body=r.read()
   if b'#EXTINF:' not in body:raise ValueError('Demo not ready')
   break
  except (OSError,ValueError):
   if attempt==99:raise
   time.sleep(1)
 subprocess.run(['systemctl','reload','nginx'],check=True)
 print(json.dumps(dict(deployed=True,backup=str(backup),service='bobtv-live-demo',channels=3)))
except BaseException:
 subprocess.run(['systemctl','disable','--now','bobtv-live-demo'],capture_output=True)
 for n,p in enumerate(files):
  if existed[n]:shutil.copy2(backup/str(n),p)
  else:p.unlink(missing_ok=True)
 subprocess.run(['systemctl','daemon-reload'])
 subprocess.run(['nginx','-t'],check=True,capture_output=True)
 subprocess.run(['systemctl','reload','nginx'])
 raise
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    host = 'ccnode.briconbric.com'
    stage = ssh(host, 'mktemp /opt/bobtv-demo-stage-XXXXXX').strip()
    ssh(host, 'cat > '+shlex.quote(stage), (ROOT/'tools/live_demo/serve.py').read_bytes())
    try:
        result = ssh(host, 'python3 -c '+shlex.quote(INSTALL.replace('STAGE', repr(stage))))
        args.receipt.write_text(result)
        print(result)
    finally:
        ssh(host, 'rm -f '+shlex.quote(stage))


if __name__ == '__main__':
    main()
