"""Receive existing OAuth app configuration locally without logging secrets."""
import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import sys
from urllib.parse import parse_qs

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from deploy_resource_relay import ssh

UPDATE = r'''
import grp,json,os,secrets,sys
from pathlib import Path
incoming=json.load(sys.stdin)
allowed={'google_client_id','google_client_secret','apple_client_id','apple_team_id','apple_key_id','apple_private_key'}
if not incoming or not set(incoming)<=allowed:raise ValueError('Unexpected OAuth fields')
if 'apple_private_key' in incoming:
 from cryptography.hazmat.primitives.serialization import load_pem_private_key
 from cryptography.hazmat.primitives.asymmetric.ec import EllipticCurvePrivateKey,SECP256R1
 key=load_pem_private_key(incoming['apple_private_key'].encode(),password=None)
 if not isinstance(key,EllipticCurvePrivateKey) or not isinstance(key.curve,SECP256R1):raise ValueError('Invalid Apple signing key')
p=Path('/etc/bobtv/accounts.json');config=json.loads(p.read_text());config.update(incoming)
temporary=p.with_name('.oauth-'+secrets.token_hex(8))
fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as f:json.dump(config,f)
os.chown(temporary,0,grp.getgrnam('bobtv').gr_gid);os.chmod(temporary,0o640);os.replace(temporary,p)
print(json.dumps({'googleConfigured':bool(config.get('google_client_id') and config.get('google_client_secret')),
 'appleConfigured':all(config.get(k) for k in ['apple_client_id','apple_team_id','apple_key_id','apple_private_key'])}))
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    token = secrets.token_urlsafe(32)
    destination = Path.home()/'.config/bobtv/accounts-secrets.json'

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass

        def reply(self, status, body):
            self.send_response(status)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(body.encode())

        def do_GET(self):
            if self.path != '/'+token: return self.reply(404, 'Not found')
            self.reply(200, '''<!doctype html><meta charset="utf-8"><title>BobTV 登录配置</title>
<style>body{font:17px system-ui;max-width:650px;margin:40px auto;padding:20px}input,textarea,button{font:inherit;padding:10px;margin:8px 0;width:100%;box-sizing:border-box}form{margin-bottom:50px}code{overflow-wrap:anywhere}</style>
<h1>BobTV 登录配置</h1><p>此页只在本机接收配置，不会把凭据显示在聊天中。</p>
<h2>Google</h2><p>授权回调地址：<code>https://bobtv.briconbric.com/api/v1/account/oauth/google/callback</code></p>
<form method="post"><input type="hidden" name="provider" value="google"><label>Web 应用 Client ID<input name="google_client_id" required autocomplete="off"></label><label>Client Secret<input type="password" name="google_client_secret" required autocomplete="off"></label><button>保存 Google 配置</button></form>
<h2>Apple</h2><p>Return URL：<code>https://bobtv.briconbric.com/api/v1/account/oauth/apple/callback</code></p>
<form method="post"><input type="hidden" name="provider" value="apple"><label>Services ID<input name="apple_client_id" required autocomplete="off"></label><label>Team ID<input name="apple_team_id" required autocomplete="off"></label><label>Key ID<input name="apple_key_id" required autocomplete="off"></label><label>P8 私钥内容<textarea name="apple_private_key" rows="8" required autocomplete="off"></textarea></label><button>保存 Apple 配置</button></form>''')

        def do_POST(self):
            if self.path != '/'+token or self.headers.get('Host') != address or self.headers.get('Origin') != 'http://'+address:
                return self.reply(403, 'Forbidden')
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 32768: raise ValueError()
                form = {k: v[0].strip() for k, v in parse_qs(self.rfile.read(size).decode()).items()}
                provider = form.pop('provider')
                expected = {'google_client_id','google_client_secret'} if provider == 'google' else {'apple_client_id','apple_team_id','apple_key_id','apple_private_key'} if provider == 'apple' else set()
                if set(form) != expected or not expected or not all(form.values()): raise ValueError()
                if provider == 'google' and not re.fullmatch(r'[A-Za-z0-9-]+\.apps\.googleusercontent\.com', form['google_client_id']): raise ValueError()
                if provider == 'apple' and not all(re.fullmatch(r'[A-Z0-9]{10}', form[k]) for k in ['apple_team_id','apple_key_id']): raise ValueError()
                result = json.loads(ssh('ccnode.briconbric.com', 'python3 -c '+shlex.quote(UPDATE), json.dumps(form)))
                values = json.loads(destination.read_text()) if destination.exists() else {}
                values.update(form)
                destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                temporary = destination.with_name('.oauth-'+secrets.token_hex(8))
                fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                with os.fdopen(fd, 'w') as out: json.dump(values, out)
                os.replace(temporary, destination)
                args.receipt.write_text(json.dumps(result, indent=2))
                self.reply(200, '<meta charset="utf-8"><h1>已保存配置</h1><p>可返回填写另一项配置。真实授权登录仍将单独验证。</p>')
            except Exception:
                self.reply(400, '<meta charset="utf-8">配置未通过校验，请返回检查。凭据未显示在日志中。')

    server = HTTPServer(('127.0.0.1', 0), Handler)
    address = '127.0.0.1:'+str(server.server_port)
    url = 'http://'+address+'/'+token
    print(url, flush=True)
    subprocess.run(['open', url], check=False)
    server.serve_forever()


if __name__ == '__main__': main()
