"""Read-only public API smoke test. No HTML or synthetic production votes."""
import gzip
import hashlib
import json
import re
import urllib.error
import urllib.request
from urllib.parse import urlencode, urlsplit

ORIGIN = 'https://bobtv.briconbric.com'


def get(path, limit=2 * 1024 * 1024):
    request = urllib.request.Request(ORIGIN + path,
        headers={'User-Agent': 'BobTV/1.0'})
    with urllib.request.urlopen(request, timeout=25) as response:
        if urlsplit(response.url).hostname != 'bobtv.briconbric.com': raise ValueError('Public redirect escaped server')
        data = response.read(limit)
        return data, response.headers.get('Content-Type', '')


def main():
    manifest = json.loads(get('/api/v1/channel-catalog/manifest')[0])
    snapshot = get(urlsplit(manifest['snapshotUrl']).path, 20 * 1024 * 1024)[0]
    if hashlib.sha256(snapshot).hexdigest() != manifest['sha256']: raise ValueError('Catalog hash mismatch')
    value = json.loads(gzip.decompress(snapshot))
    channels = value['channels']
    candidates = [{'name': channel['name'], 'url': route['url']}
        for channel in channels if re.search(r'GOOD\s*TV|CCTV[- ]?1\b', channel.get('name', ''), re.I)
        for route in channel.get('routes', [])]
    candidates.sort(key=lambda row: 0 if 'GOOD' in row['name'].upper() else 1)
    results = []
    for row in candidates[:12]:
        root = row.get('url') or row.get('streamUrl')
        if not root: continue
        path = '/api/v1/egress/resource?' + urlencode({'kind': 'media', 'url': root})
        try:
            body, mime = get(path, 512 * 1024)
            hops = 1
            for _ in range(3):
                if not body.lstrip(b'\xef\xbb\xbf').startswith(b'#EXTM3U'): break
                targets = [line.strip() for line in body.decode('utf-8-sig').splitlines() if line.strip() and not line.startswith('#')]
                if not targets or any(urlsplit(url).hostname != 'bobtv.briconbric.com' for url in targets): raise ValueError('Unrewritten playlist child')
                body, mime = get(urlsplit(targets[-1] if '#EXTINF' in body.decode('utf-8-sig') else targets[0]).path + '?' + urlsplit(targets[-1] if '#EXTINF' in body.decode('utf-8-sig') else targets[0]).query, 65536)
                hops += 1
            media = body[:1] == b'G' or b'ftyp' in body[:32] or b'styp' in body[:32] or b'moof' in body[:32] or body[:1] == b'\xff'
            if media and len(body) >= 512:
                results.append({'channel': row['name'], 'serverHops': hops, 'mediaBytes': len(body), 'contentType': mime})
                if len(results) >= 2: break
        except (ValueError, OSError, urllib.error.URLError): continue
    if not results: raise RuntimeError('No tested route yielded media through the public gateway')
    try:
        get('/api/v1/egress/resource?' + urlencode({'kind': 'media', 'url': 'http://127.0.0.1:8917/'}))
        raise ValueError('Private URL was accepted')
    except urllib.error.HTTPError as error:
        if error.code != 403: raise
    logos = json.loads(get('/api/v1/egress/logo-index')[0])
    print(json.dumps({'httpsGateway': 'ok', 'privateOriginsRejected': True,
        'mediaThroughServer': results, 'serverLogoIndex': len(logos['logos'])}, ensure_ascii=False))


if __name__ == '__main__': main()
