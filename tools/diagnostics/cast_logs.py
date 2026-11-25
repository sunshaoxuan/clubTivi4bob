#!/usr/bin/env python3
"""List and privately download cast diagnostic batches through authenticated SSH."""
import argparse
import base64
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

REMOTE = r'''
import base64, gzip, json, sqlite3, sys, time
from pathlib import Path
args=json.load(sys.stdin)
path=Path('/var/lib/bobtv-diagnostics/batches.sqlite3')
if not path.is_file():
    raise SystemExit('Diagnostic database unavailable')
conn=sqlite3.connect(path.as_uri()+'?mode=ro', uri=True)
conn.row_factory=sqlite3.Row
if args.get('download'):
    row=conn.execute('SELECT id,body FROM batches WHERE id=? AND expires>? AND body IS NOT NULL', (args['download'],int(time.time()))).fetchone()
    if row is None: raise SystemExit('Batch missing or expired')
    body=json.loads(row['body'])
    if not any(e['event'].startswith('cast_') for e in body['entries']):
        raise SystemExit('Batch contains no casting diagnostics')
    print(base64.b64encode(gzip.compress(row['body'], mtime=0)).decode('ascii'))
else:
    rows=conn.execute('SELECT id,body,received,state FROM batches WHERE received>=? AND expires>? AND body IS NOT NULL ORDER BY received DESC,id DESC LIMIT 2000', (args['after'],int(time.time())))
    count=0
    for row in rows:
        body=json.loads(row['body'])
        if args.get('terminal') and body.get('terminalFingerprint') != args['terminal']: continue
        events=[e for e in body['entries'] if e['event'].startswith('cast_')]
        if not events: continue
        print(json.dumps({'id':row['id'],'received':row['received'],'state':row['state'],
            'installationId':body['installationId'],
            'terminalFingerprint':body.get('terminalFingerprint'),
            'sessions':sorted({e['requestId'] for e in events if 'requestId' in e}),
            'events':len(events),'lastEvent':events[-1]['event'],
            'failures':sum('failed' in e['event'] or e.get('accepted') is False for e in events)}))
        count+=1
        if count>=args['limit']: break
conn.close()
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--after', type=int, default=0, help='Unix received timestamp, inclusive')
    parser.add_argument('--limit', type=int, default=30)
    parser.add_argument('--terminal', help='Filter by full anonymous terminal fingerprint')
    parser.add_argument('--download', help='64-character batch digest from the listing')
    parser.add_argument('--output', type=Path, help='New private .json.gz archive for downloaded batch')
    parser.add_argument('--key', default='/Users/shou/Desktop/Secure/sunsxaws.pem')
    args = parser.parse_args()
    if args.terminal and not re.fullmatch('[a-f0-9]{64}', args.terminal):
        parser.error('terminal must be a 64-character anonymous fingerprint')
    if not 1 <= args.limit <= 200:
        parser.error('limit must be between 1 and 200')
    if args.download and (not re.fullmatch('[a-f0-9]{64}', args.download) or not args.output):
        parser.error('download requires a valid digest and --output')
    if args.download and not str(args.output).endswith('.json.gz'):
        parser.error('compressed download output must end with .json.gz')
    import shlex
    result = subprocess.run(['ssh', '-i', args.key, '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=10', 'root@ccnode.briconbric.com',
        'python3 -c ' + shlex.quote(REMOTE)],
        input=json.dumps({'after': args.after, 'limit': args.limit, 'download': args.download, 'terminal': args.terminal}),
        capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise SystemExit(result.stderr.strip() or 'Remote diagnostic read failed')
    if args.download:
        # No overwrite, no publicly readable diagnostic payload.
        archive = base64.b64decode(result.stdout.strip(), validate=True)
        body = gzip.decompress(archive)
        if hashlib.sha256(body).hexdigest() != args.download:
            raise SystemExit('Downloaded diagnostic digest mismatch')
        json.loads(body)
        with os.fdopen(os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as file:
            file.write(archive)
        print(args.output.resolve())
    else:
        print(result.stdout, end='')


if __name__ == '__main__':
    main()
