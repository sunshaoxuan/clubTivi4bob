"""Conservative identity for a public HTTP media endpoint.

Path spelling, query parameters, HTTP/HTTPS and non-default ports stay distinct.
Never infer identity from a channel name or remove authentication parameters.
"""
from urllib.parse import urlsplit


def canonical_route_url(url):
    parsed = urlsplit(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        return url
    host = parsed.hostname.lower()
    if ":" in host:
        host = f"[{host}]"
    port = parsed.port
    if port is not None and port != (443 if parsed.scheme == "https" else 80):
        host += f":{port}"
    # Preserve even an empty query marker, which can affect request signing.
    suffix = url.split("://", 1)[1]
    start = next((i for i, char in enumerate(suffix) if char in "/?#"), len(suffix))
    suffix = suffix[start:]
    if not suffix or suffix.startswith("?"):
        suffix = "/" + suffix
    return f"{parsed.scheme}://{host}{suffix}"
