"""Administrator-run auxiliary resource refresh; clients never query GitHub."""
import json
import os
import tempfile
from pathlib import Path
from urllib.parse import quote

from egress_gateway import DATA, fetch_small


def refresh():
    result = {}
    for directory in ('united-states', 'international', 'canada', 'united-kingdom'):
        body, status, _ = fetch_small('https://api.github.com/repos/tv-logo/tv-logos/contents/countries/' + directory, 'data')
        if status != 200: raise RuntimeError('Logo index upstream unavailable')
        entries = json.loads(body)
        if not isinstance(entries, list): raise ValueError('Invalid logo index')
        for item in entries:
            name = item.get('name', '')
            if not name.endswith('.png') or name.startswith('0_'): continue
            key = name[:-4].lower()
            for suffix in ('-us', '-uk', '-ca', '-int'):
                if key.endswith(suffix):
                    key = key[:-len(suffix)]
                    break
            result.setdefault(key, 'https://raw.githubusercontent.com/tv-logo/tv-logos/main/countries/' + directory + '/' + quote(name))
    if not result: raise ValueError('Empty logo index')
    path = Path(DATA) / 'egress-logo-index.json'
    descriptor, temporary = tempfile.mkstemp(prefix='.logo-index-', dir=path.parent)
    with os.fdopen(descriptor, 'w') as output: json.dump(result, output)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
    print(json.dumps({'logos': len(result)}))


if __name__ == '__main__': refresh()
