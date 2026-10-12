"""Media-only sender boundary. Never send video via the resource relay."""
import ipaddress
from urllib.parse import urlsplit


def server_or_local_url(url):
    parsed = urlsplit(url)
    if not parsed.scheme: return url  # Local recordings, never a network URL.
    if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError('Unsupported sender resource')
    if parsed.hostname == 'cndrp.com' and parsed.path.startswith('/bobtv/'):
        raise ValueError('Resource relay cannot carry video')
    if parsed.scheme in ('http', 'https'):
        return url
    host = parsed.hostname.lower()
    if host == 'localhost' or host.endswith('.local'): return url
    try:
        address = ipaddress.ip_address(host)
        if address.is_loopback or address.is_link_local: return url
        networks = ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', 'fc00::/7')
        if any(address in ipaddress.ip_network(network) for network in networks): return url
    except ValueError:
        pass
    raise ValueError('Unsupported video resource')
