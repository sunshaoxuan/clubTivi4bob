"""Refresh DB-IP Lite city and ASN databases over verified HTTPS.

Data is CC BY 4.0, https://db-ip.com/db/lite.php. This script never queries an
external geolocation API with a viewer's IP. Existing files survive failures.
"""
import gzip
import hashlib
import json
import os
import re
import tempfile
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

import maxminddb
from catalog_inventory import DATA


class _HttpsRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urlsplit(newurl)
        if parsed.scheme != 'https' or parsed.hostname not in ('db-ip.com', 'www.db-ip.com', 'download.db-ip.com'):
            raise ValueError('Unexpected network database redirect')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url, timeout):
    request = urllib.request.Request(url, headers={'User-Agent': 'BobTV/1.0'})
    return urllib.request.build_opener(_HttpsRedirect()).open(request, timeout=timeout)


def download(kind, directory):
    page = f'https://db-ip.com/db/download/ip-to-{kind}-lite'
    with fetch(page, 30) as response:
        if urlsplit(response.url).scheme != 'https': raise ValueError('Insecure database page')
        text = response.read(512 * 1024).decode('utf-8')
    links = re.findall(r'https://download\.db-ip\.com/free/dbip-' + kind + r'-lite-\d{4}-\d{2}\.mmdb\.gz', text)
    if not links: raise ValueError('No current official MMDB download')
    url = sorted(set(links))[-1]
    fd, temporary = tempfile.mkstemp(prefix='.' + kind + '-', dir=directory)
    path = Path(temporary)
    try:
        digest = hashlib.sha256()
        size = 0
        with os.fdopen(fd, 'wb') as output:
            with fetch(url, 60) as response:
                if urlsplit(response.url).scheme != 'https': raise ValueError('Insecure database download')
                with gzip.GzipFile(fileobj=response) as archive:
                    while True:
                        chunk = archive.read(1024 * 1024)
                        if not chunk: break
                        size += len(chunk)
                        if size > 256 * 1024 * 1024: raise ValueError('Oversized database')
                        output.write(chunk)
                        digest.update(chunk)
            output.flush()
            os.fsync(output.fileno())
        with maxminddb.open_database(str(path)) as reader:
            if reader.metadata().node_count < 1000: raise ValueError('Empty network database')
            reader.get('8.8.8.8')
        path.chmod(0o640)
        os.replace(path, directory / (kind + '.mmdb'))
        return {'source': url, 'sha256': digest.hexdigest(), 'bytes': size}
    finally:
        path.unlink(missing_ok=True)


def update(directory=None):
    directory = Path(directory or os.environ.get('BOBTV_NETWORK_DB_DIR', DATA / 'network-db'))
    directory.mkdir(parents=True, exist_ok=True)
    report = {'attribution': 'IP Geolocation by DB-IP, https://db-ip.com, CC BY 4.0'}
    for kind in ('city', 'asn'):
        report[kind] = download(kind, directory)
    fd, temporary = tempfile.mkstemp(prefix='.metadata-', dir=directory)
    with os.fdopen(fd, 'w') as output:
        json.dump(report, output)
    os.replace(temporary, directory / 'metadata.json')
    return report


if __name__ == '__main__':
    print(json.dumps(update()))
