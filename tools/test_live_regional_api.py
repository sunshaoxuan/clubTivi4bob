"""Read-only HTTPS smoke test. Never inject synthetic health into production."""
import gzip
import hashlib
import json
import urllib.error
import urllib.request
from urllib.parse import urljoin

BASE = 'https://bobtv.briconbric.com'


def request(path, body=None, headers=None):
    headers = {'User-Agent': 'BobTV/1.0', 'Accept': 'application/json', **(headers or {})}
    if body is not None:
        headers = {**headers, 'Content-Type': 'application/json'}
        body = json.dumps(body).encode()
    req = urllib.request.Request(urljoin(BASE, path), data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as response:
        if response.url != req.full_url: raise ValueError('Unexpected API redirect')
        return response.read(32 * 1024 * 1024)


def main():
    profile = json.loads(request('/api/v1/channel-catalog/network-profile'))
    forged = json.loads(request('/api/v1/channel-catalog/network-profile', headers={
        'X-Forwarded-For': '1.1.1.1', 'X-Real-IP': '1.1.1.1', 'CF-IPCountry': 'CN'}))
    assert profile['networkId'] == forged['networkId']
    assert profile['schemaVersion'] == 1 and 'ip' not in profile
    manifest = json.loads(request('/api/v1/channel-catalog/manifest'))
    snapshot = request(manifest['snapshotUrl'])
    assert hashlib.sha256(snapshot).hexdigest() == manifest['sha256']
    data = json.loads(gzip.decompress(snapshot))
    assert data['channels']
    selected = [r['url'] for c in data['channels'] if c['name'].upper().startswith('CCTV') for r in c['routes']][:6]
    if not selected: selected = [r['url'] for c in data['channels'] for r in c['routes']][:6]
    ranking = json.loads(request('/api/v1/channel-catalog/rank', {'schemaVersion': 1, 'urls': selected}))
    assert ranking['profile']['networkId'] == profile['networkId']
    assert len(ranking['routes']) == len(set(selected))
    assert all(0 <= r['score'] <= 1 and r['url'] in selected for r in ranking['routes'])
    try:
        request('/api/v1/channel-catalog/probe-targets?nodeId=unregistered')
        raise AssertionError('Anonymous probe unexpectedly accepted')
    except urllib.error.HTTPError as exc:
        assert exc.code == 401
    print(json.dumps({'httpsApi': 'ok', 'profile': {k: profile[k] for k in ('countryCode', 'regionCode', 'asn', 'networkId')},
                      'spoofedHeadersIgnored': True, 'catalogVersion': manifest['version'],
                      'catalogRoutes': manifest['routeCount'], 'rankedCandidates': len(ranking['routes']),
                      'anonymousProbeRejected': True}))


if __name__ == '__main__': main()
