"""Fail the local audit if a raw public-network constructor is added again."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def audit():
    failures = []
    files = list((ROOT / 'lib').rglob('*.dart'))
    for path in files:
        if path.name.endswith(('.g.dart', '.freezed.dart')): continue
        text = path.read_text()
        relative = path.relative_to(ROOT).as_posix()
        if path.name != 'server_egress.dart' and re.search(r'\bDio\(', text):
            failures.append(relative + ': raw Dio constructor')
        if path.name != 'server_image.dart' and re.search(r'(?<!Server)\bImage\.network\(', text):
            failures.append(relative + ': raw network image')
        for match in re.finditer(r'\bMedia\(([^\n]*)', text):
            if not match.group(1).startswith('ServerEgress.mediaUrl('):
                failures.append(relative + ': raw native player URL')
        for match in re.finditer(r'(?:imageUrl:\s*|CachedNetworkImageProvider\()([^\n]+)', text):
            if not match.group(1).startswith('ServerEgress.imageUrl('):
                failures.append(relative + ': raw cached image URL')
    native = (ROOT / 'tools' / 'airplay' / 'bobtv_airplay.py').read_text()
    if 'server_or_local_url(url)' not in native: failures.append('native AirPlay input unguarded')
    if 'ServerEgress.installGuard();' not in (ROOT / 'lib' / 'main.dart').read_text(): failures.append('runtime guard missing')
    if failures: raise RuntimeError('\n'.join(failures))
    return {'auditedDartFiles': len(files), 'rawPublicConstructors': 0,
        'nativePlayback': 'direct video origin; resource relay excluded', 'directPublicFallback': False,
        'intentionalExceptions': ['loopback codec bridge', 'LAN cast/control',
            'local recordings', 'explicit external-browser navigation']}


if __name__ == '__main__': print(json.dumps(audit(), ensure_ascii=False))
