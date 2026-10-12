"""Resource-node probes and authenticated preservation of client attribution."""
import hashlib
import hmac
import ipaddress
import json
import os
import time
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import Response

router = APIRouter(prefix='/api/v1/resource-node')
PROBE_VERSION = 'bobtv-resource-v1'
PROBE_BODY = bytes((i * 73 + (i >> 8) * 19) & 255 for i in range(65536))


def signature(secret, method, path, address, stamp):
    payload = '\n'.join((method, path, address, stamp)).encode()
    return hmac.new(secret.encode(), payload, hashlib.sha256).hexdigest()


def trusted_client(request, now=None):
    """A forwarded address alone never changes attribution or rate limiting."""
    if not request.headers.get('x-bobtv-relay-auth'):
        return None
    try:
        path = Path(os.environ.get('BOBTV_RESOURCE_RELAYS', '/etc/bobtv/resource-relays.json'))
        config = json.loads(path.read_text())
        # Cloudflare's connecting IP is accepted only from its registered IP
        # ranges, using the origin's existing trusted attribution boundary.
        from source_candidates import _attribution
        peer, _ = _attribution(request)
        node = config['nodes'][request.headers['x-bobtv-relay-node']]
        if node.get('enabled') is not True or peer not in node['addresses']:
            raise ValueError()
        address = str(ipaddress.ip_address(request.headers['x-bobtv-relay-client']))
        stamp = request.headers['x-bobtv-relay-time']
        now = time.time() if now is None else now
        if not stamp.isdecimal() or abs(now - int(stamp)) > 60:
            raise ValueError()
        expected = signature(node['secret'], request.method, request.url.path, address, stamp)
        if not hmac.compare_digest(expected, request.headers['x-bobtv-relay-auth']):
            raise ValueError()
        return address
    except (OSError, ValueError, KeyError, TypeError):
        raise HTTPException(403, 'Invalid resource relay') from None


@router.api_route('/probe', methods=['GET', 'HEAD'])
def probe(request: Request):
    return Response(PROBE_BODY if request.method == 'GET' else b'',
        media_type='application/octet-stream', headers={
            'Content-Length': str(len(PROBE_BODY)), 'Cache-Control': 'no-store',
            'X-BobTV-Probe': PROBE_VERSION, 'X-BobTV-Node': 'origin'})
