"""Optional regional probe, run only on an administrator-controlled node.

Config contains HTTPS website URL, registered nodeId and a private bearer token.
Transport evidence is explicitly distinct from decoded playback evidence.
"""
import concurrent.futures
import json
import os
import urllib.request
import uuid
from pathlib import Path
from urllib.parse import urlencode, urlsplit

from process_channel_inventory import probe


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('Probe API redirects are not permitted')


def run(settings):
    base = settings['baseUrl'].rstrip('/')
    parsed = urlsplit(base)
    if parsed.scheme != 'https' or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError('Probe API requires HTTPS')
    node, token = settings['nodeId'], settings['token']
    headers = {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'}
    opener = urllib.request.build_opener(_NoRedirect())
    path = base + '/api/v1/channel-catalog/'
    request = urllib.request.Request(path + 'probe-targets?' + urlencode({'nodeId': node}), headers=headers)
    with opener.open(request, timeout=20) as response:
        if urlsplit(response.url).netloc != parsed.netloc or urlsplit(response.url).scheme != 'https': raise ValueError('Unexpected probe redirect')
        payload = json.loads(response.read(256 * 1024))
    urls = payload['urls']
    if payload.get('schemaVersion') != 1 or not isinstance(urls, list) or len(urls) > 100: raise ValueError('Invalid targets')
    if not urls: return {'checked': 0}
    def measure(url):
        success = probe(url)
        return {'id': uuid.uuid4().hex, 'url': url, 'success': success, 'observation': 'probe'}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(measure, urls))
    # Avoid publishing mass failure during a disconnected probe run. Successful
    # observations can still be submitted independently of that guard.
    if len(results) >= 8 and not any(item['success'] for item in results):
        return {'checked': len(results), 'networkGuard': True}
    request = urllib.request.Request(path + 'probe-results', headers=headers,
        data=json.dumps({'schemaVersion': 1, 'nodeId': node, 'results': results}).encode())
    with opener.open(request, timeout=30) as response:
        if urlsplit(response.url).netloc != parsed.netloc or urlsplit(response.url).scheme != 'https': raise ValueError('Unexpected probe redirect')
        receipts = json.loads(response.read(128 * 1024))
    return {'checked': len(results), 'accepted': sum(r['status'] == 'applied' for r in receipts['receipts'])}


if __name__ == '__main__':
    path = Path(os.environ.get('BOBTV_PROBE_AGENT_CONFIG', '/etc/bobtv/probe-agent.json'))
    print(json.dumps(run(json.loads(path.read_text()))))
