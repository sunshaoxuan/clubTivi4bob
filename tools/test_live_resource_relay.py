"""Public relay checks. Writes one synthetic diagnostic, no channel mutations."""
import concurrent.futures
import hashlib
import json
from datetime import datetime, timezone
import urllib.error
import urllib.request

PRIMARY = 'https://bobtv.briconbric.com'
RELAY = 'https://cndrp.com/bobtv'


def request(base, path, body=None, headers=None):
    value = urllib.request.Request(base + path, data=body,
        headers={'User-Agent':'BobTV/1.1', 'Accept-Encoding':'identity', **(headers or {})})
    with urllib.request.urlopen(value, timeout=45) as response:
        if response.url != base + path: raise ValueError('Unexpected redirect')
        return response.status, dict(response.headers), response.read()


def main():
    result = {'checkedAt': datetime.now(timezone.utc).isoformat()}
    sample = bytes((i * 73 + (i >> 8) * 19) & 255 for i in range(65536))
    for base, expected in [(PRIMARY, 'origin'), (RELAY, 'cndrp')]:
        status, headers, body = request(base, '/api/v1/resource-node/probe')
        assert status == 200 and body == sample and headers.get('x-bobtv-node', headers.get('X-BobTV-Node')) == expected
    manifests = [json.loads(request(base, '/api/v1/channel-catalog/manifest')[2]) for base in [PRIMARY, RELAY]]
    assert manifests[0] == manifests[1]
    snapshot = manifests[1]['snapshotUrl']
    cached = []
    for _ in range(2):
        status, headers, body = request(RELAY, snapshot)
        assert status == 200 and hashlib.sha256(body).hexdigest() == manifests[1]['sha256']
        cached.append(headers.get('x-bobtv-cache', headers.get('X-BobTV-Cache')))
    assert cached[-1] == 'HIT'
    result['snapshot'] = {'sha256': manifests[1]['sha256'], 'bytes':len(body), 'cache':cached}
    profiles = [json.loads(request(base, '/api/v1/channel-catalog/network-profile')[2]) for base in [PRIMARY, RELAY]]
    assert profiles[0]['networkId'] == profiles[1]['networkId']
    result['profilePreserved'] = profiles[0]['networkId']
    data = json.dumps({'time':result['checkedAt'],'event':'resource_relay_validation',
        'platform':'test','source':'relay'}, separators=(',',':')).encode() + b'\n'
    headers = {'Content-Type':'application/x-ndjson'}
    first = request(RELAY, '/api/v1/logs', data, headers)
    second = request(PRIMARY, '/api/v1/logs', data, headers)
    assert first[0] in (200,201) and second[0] == 200
    assert json.loads(first[2])['id'] == json.loads(second[2])['id'] == hashlib.sha256(data).hexdigest()
    assert json.loads(second[2])['duplicate'] is True
    assert first[1].get('x-bobtv-cache',first[1].get('X-BobTV-Cache')) == 'BYPASS'
    result['uploadCanonicalReceipt'] = json.loads(first[2])['id']
    platforms = ['windows-x64','windows-arm64','macos-x64','macos-arm64','android-arm','android-arm64','android-x64']
    for platform in platforms:
        path = '/updates/'+platform+'/latest.json'
        versions = [json.loads(request(base,path)[2]) for base in [PRIMARY,RELAY]]
        assert versions[0] == versions[1]
    result['updateFeedPlatforms'] = platforms
    feed = json.loads(request(RELAY,'/updates/windows-arm64/latest.json')[2])
    archive = feed['archive'].removeprefix(PRIMARY)
    status, _, partial = request(RELAY,archive,headers={'Range':'bytes=0-65535'})
    assert status == 206 and len(partial) == 65536 and partial[:2] == b'PK'
    result['rangeBytes'] = len(partial)
    # Full download verifies the cached package and publisher digest unchanged.
    status, headers, package = request(RELAY,archive)
    assert status == 200 and len(package) == feed['bytes']
    assert hashlib.sha256(package).hexdigest() == feed['sha256']
    result['package'] = {'bytes': len(package), 'sha256':feed['sha256']}
    status, headers, _ = request(RELAY,archive,headers={'Range':'bytes=0-65535'})
    assert status == 206 and headers.get('x-bobtv-cache',headers.get('X-BobTV-Cache')) == 'HIT'
    for path in ['/api/v1/egress/resource?kind=media&url=https%3A%2F%2Fexample.org%2Flive.m3u8', '/admin']:
        try: request(RELAY,path)
        except urllib.error.HTTPError as error: assert error.code == 403
        else: raise AssertionError('Video/admin resource accepted')
    result['mediaRejected'] = True
    print(json.dumps(result,ensure_ascii=False,indent=2))


if __name__ == '__main__': main()
