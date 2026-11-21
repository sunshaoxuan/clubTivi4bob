"""Short-lived, read-only EPG proofs for server publication and health workers."""
import hashlib
import hmac
import os
from pathlib import Path
import re
import time
from urllib.parse import urlsplit
from urllib.request import BaseHandler

STAMP = 'X-BobTV-EPG-Read-Time'
PROOF = 'X-BobTV-EPG-Read-Auth'


def scoped(path, method):
    return method in {'GET', 'HEAD'} and bool(re.fullmatch(
        r'/api/v1/epg/(?:manifest|snapshots/[a-f0-9]{64}\.json\.gz)', path))


def key():
    path = Path(os.environ.get('BOBTV_INTERNAL_EPG_KEY', '/etc/bobtv/epg-internal-read.key'))
    if not path.is_file() or path.is_symlink() or path.stat().st_size != 32:
        return None
    return path.read_bytes()


def digest(secret, method, path, stamp):
    return hmac.new(secret, f'{method}\n{path}\n{stamp}'.encode(), hashlib.sha256).hexdigest()


def headers_for(url, method='GET', *, now=None):
    parsed = urlsplit(url)
    if (parsed.scheme != 'https' or parsed.username or parsed.password
            or parsed.port not in (None, 443) or parsed.query or parsed.fragment):
        return {}
    path = parsed.path
    if parsed.hostname == 'cndrp.com' and path.startswith('/bobtv/'):
        path = path[len('/bobtv'):]
    elif parsed.hostname != 'bobtv.briconbric.com':
        return {}
    if not scoped(path, method):
        return {}
    secret = key()
    if secret is None:
        return {}
    stamp = str(int(time.time() if now is None else now))
    return {STAMP: stamp, PROOF: digest(secret, method, path, stamp)}


def authorized(method, path, headers, *, now=None):
    if not scoped(path, method):
        return False
    stamp = headers.get(STAMP, '')
    proof = headers.get(PROOF, '')
    if not re.fullmatch(r'[0-9]{1,12}', stamp) or not re.fullmatch(r'[a-f0-9]{64}', proof):
        return False
    if abs((time.time() if now is None else now) - int(stamp)) > 30:
        return False
    secret = key()
    return secret is not None and hmac.compare_digest(proof, digest(secret, method, path, stamp))


class ReadAuthHandler(BaseHandler):
    def http_request(self, request):
        # urllib copies ordinary request headers into redirect requests.
        # Recompute the proof for each reviewed destination and keep it out
        # of the headers copied by HTTPRedirectHandler.
        for name in (STAMP, PROOF):
            request.remove_header(name.capitalize())
        for name, value in headers_for(request.full_url, request.get_method()).items():
            request.add_unredirected_header(name, value)
        return request

    https_request = http_request
