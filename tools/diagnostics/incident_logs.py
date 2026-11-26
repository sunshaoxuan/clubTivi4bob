"""Privately retrieve one incident and reassemble its acknowledged log batches."""
import argparse
import base64
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import zipfile

REMOTE = r'''
import base64,gzip,json,sqlite3,sys,time
from pathlib import Path
a=json.load(sys.stdin)
p=Path('/var/lib/bobtv-diagnostics/batches.sqlite3')
c=sqlite3.connect(p.as_uri()+'?mode=ro',uri=True);c.row_factory=sqlite3.Row
result=[]
for r in c.execute('SELECT id,body,received,state FROM batches WHERE installation=? AND expires>? AND body IS NOT NULL ORDER BY received,id', (a['installation'],int(time.time()))):
 b=json.loads(r['body'])
 if any(e.get('incidentId')==a['incident'] for e in b['entries']):
  result.append({'id':r['id'],'received':r['received'],'state':r['state'],'body':base64.b64encode(r['body']).decode()})
print(base64.b64encode(gzip.compress(json.dumps(result).encode())).decode())
'''


def write_packet(path, entries, manifest):
    """All times and error facts remain as recorded; no missing data is inferred."""
    unique = {}
    for entry in entries:
        key = json.dumps({k: v for k, v in entry.items() if k != 'breadcrumb'},
                         sort_keys=True, ensure_ascii=False)
        unique.setdefault(key, entry)
    timeline = sorted(unique.values(), key=lambda e: e['time'])
    files = {
        'manifest.json': manifest,
        'timeline.json': timeline,
        'environment.json': [e for e in timeline if any(
            k in e for k in ('cpuModel', 'totalMemoryBytes', 'ffmpegAvailable',
                            'pyatvVersion', 'ffmpegVersion', 'receiverModel'))],
        'network.json': [e for e in timeline if any(
            k in e for k in ('networkProbe', 'receiverAddress', 'bindAddress'))],
        'failures.json': [e for e in timeline if any(
            k in e for k in ('errorType', 'osErrorCode', 'nativeStackFrames', 'stackFrames'))],
        'authentication.json': [e for e in timeline if any(
            k in e for k in ('authMode', 'authPhase', 'authReason', 'authTlvError'))],
    }
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
        with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for name, value in files.items():
                archive.writestr(name, json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    return len(timeline)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installation', required=True)
    parser.add_argument('--incident', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--key', default='/Users/shou/Desktop/Secure/sunsxaws.pem')
    args = parser.parse_args()
    if not all(re.fullmatch(r'[a-f0-9]{32}', value) for value in
               (args.installation, args.incident)):
        parser.error('Installation and incident IDs must be 32 hexadecimal characters')
    if args.output.suffix != '.zip':
        parser.error('Output must be a new .zip file')
    result = subprocess.run(['ssh', '-i', args.key, '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=10', 'root@ccnode.briconbric.com',
        'python3 -c ' + shlex.quote(REMOTE)],
        input=json.dumps({'installation': args.installation, 'incident': args.incident}),
        capture_output=True, text=True, timeout=45)
    if result.returncode:
        raise SystemExit(result.stderr.strip() or 'Diagnostic retrieval failed')
    batches = json.loads(gzip.decompress(base64.b64decode(result.stdout)))
    if not batches:
        raise SystemExit('No retained uploaded records for this incident')
    entries, receipts = [], []
    for batch in batches:
        raw = base64.b64decode(batch.pop('body'))
        if hashlib.sha256(raw).hexdigest() != batch['id']:
            raise SystemExit('Server diagnostic digest mismatch')
        entries.extend(e for e in json.loads(raw)['entries']
                       if e.get('incidentId') == args.incident)
        receipts.append(batch)
    count = write_packet(args.output, entries, {
        'incidentId': args.incident, 'installationId': args.installation,
        'origin': 'server_download', 'batches': receipts,
        'completeAfterWindow': any(e['event'] == 'diagnostic_incident_completed'
                                  for e in entries),
        'interrupted': any(e['event'] == 'diagnostic_incident_interrupted' for e in entries),
        'note': 'Absent fields were not captured. Inspect probe status, age and truncation flags.',
    })
    print(json.dumps({'output': str(args.output.resolve()), 'events': count}))


if __name__ == '__main__':
    main()
