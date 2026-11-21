"""Collect SMTP credentials on loopback and validate them without sending mail."""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    token = secrets.token_urlsafe(32)
    credentials = Path.home()/'.config/bobtv/accounts-secrets.json'

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, status, body):
            self.send_response(status)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(body.encode())

        def do_GET(self):
            if self.path != '/'+token:
                return self.reply(404, 'Not found')
            self.reply(200, '''<!doctype html><meta charset="utf-8"><title>BobTV 邮件配置</title>
<style>body{font:18px system-ui;max-width:540px;margin:80px auto;padding:20px}input,button{font:inherit;padding:12px;margin:12px 0;width:100%;box-sizing:border-box}</style>
<h1>BobTV 邮件配置</h1><p>发信邮箱：postmaster@bobuy.cc<br>加密服务器：mail.briconbric.com:465</p>
<p>请输入此邮箱的 SMTP 密码。只验证登录并启用配置，不发送测试邮件。</p>
<form method="post"><input type="password" name="password" autocomplete="current-password" required><button>验证并保存</button></form>''')

        def do_POST(self):
            if self.path != '/'+token or self.headers.get('Host') != address:
                return self.reply(403, 'Forbidden')
            if self.headers.get('Origin') != 'http://'+address:
                return self.reply(403, 'Forbidden')
            length = int(self.headers.get('Content-Length', '0'))
            if length < 1 or length > 8192:
                return self.reply(400, 'Invalid input')
            password = parse_qs(self.rfile.read(length).decode()).get('password', [''])[0]
            if not password:
                return self.reply(400, '请输入密码')
            credentials.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            values = json.loads(credentials.read_text()) if credentials.exists() else {}
            values.update(smtp_host='mail.briconbric.com', smtp_port=465,
                          smtp_user='postmaster@bobuy.cc', smtp_from='postmaster@bobuy.cc', smtp_password=password)
            temporary = credentials.with_name('.smtp-'+secrets.token_hex(8))
            fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(fd, 'w') as output:
                json.dump(values, output)
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('configure_smtp.py')),
                                     '--credentials', str(temporary), '--receipt', str(args.receipt)],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if result.returncode:
                temporary.unlink(missing_ok=True)
                return self.reply(400, '验证未通过，请返回重新输入。密码未保存。')
            os.replace(temporary, credentials)
            self.reply(200, '<meta charset="utf-8"><h1>已验证并保存</h1><p>BobTV 邮箱验证码服务已启用，可关闭此页。</p>')

    server = HTTPServer(('127.0.0.1', 0), Handler)
    address = '127.0.0.1:'+str(server.server_port)
    url = 'http://'+address+'/'+token
    print(url, flush=True)
    subprocess.run(['open', url], check=False)
    server.serve_forever()


if __name__ == '__main__':
    main()
