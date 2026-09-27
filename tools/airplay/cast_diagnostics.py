"""Small rotating native-cast log with an explicit non-secret field allowlist."""
import json
import os
from pathlib import Path
import time
import re
import sys

FIELDS = {'stage', 'count', 'audioPackets', 'status', 'errorType', 'reason',
          'requests', 'elapsedMs', 'lagMs', 'provided', 'bytes', 'mode',
          'sourceEnded', 'decoderExit', 'hlsLiveEdge'}


def record(item):
    try:
        if sys.platform == 'darwin' and 'LOCALAPPDATA' not in os.environ:
            folder = Path.home() / 'Library' / 'Application Support' / 'BobTV' / 'AirPlay'
        else:
            folder = Path(os.environ.get('LOCALAPPDATA', str(Path.home()))) / 'BobTV' / 'AirPlay'
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / 'native-cast.log'
        if path.exists() and path.stat().st_size > 256 * 1024:
            path.replace(folder / 'native-cast.previous.log')
        clean = {k: v for k, v in item.items() if k in FIELDS
                 and isinstance(v, (str, int, float, bool))
                 and (not isinstance(v, str) or re.fullmatch(r'[A-Za-z0-9_-]{1,80}', v))}
        # Values originate only from fixed stage/reason enums and numeric metrics.
        clean['time'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        with path.open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(clean) + '\n')
    except OSError:
        pass
