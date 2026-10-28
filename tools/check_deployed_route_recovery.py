"""Exercise route admission against an isolated copy of the deployed catalog.

The synthetic test route is never fetched or written to the public authority.
The existing deployed matcher/publisher is imported unchanged for compatibility.
"""
import argparse
import fcntl
import json
from pathlib import Path
import shutil
import sqlite3
import sys
import tempfile
import time


def check(site, staging, data):
    sys.path[:0] = [str(staging), str(site)]
    import channel_route_recovery as recovery
    from process_channel_inventory import process
    with tempfile.TemporaryDirectory(prefix='route-recovery-canary-', dir=data) as temporary:
        target_dir = Path(temporary)
        with (data / 'catalog-process.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_SH)
            manifest, payload = recovery.catalog(data)
            catalog = target_dir / 'channel-catalog'
            (catalog / 'snapshots').mkdir(parents=True)
            shutil.copyfile(data / 'channel-catalog/manifest.json', catalog / 'manifest.json')
            name = manifest['sha256'] + '.json.gz'
            shutil.copyfile(data / 'channel-catalog/snapshots' / name, catalog / 'snapshots' / name)
            with sqlite3.connect(f'file:{data}/channel_inventory.sqlite3?mode=ro', uri=True) as source:
                with sqlite3.connect(target_dir / 'channel_inventory.sqlite3') as destination:
                    source.backup(destination, pages=128)
        channel = next(c for c in payload['channels'] if c['id'] == 'channel-3a0709a7a9693981364a5a95')
        profile = {'channelId': channel['id'],
            'metadataHash': recovery.identity(payload, channel, include_routes=False),
            'operator': 'SYNTHETIC TEST ONLY', 'countryCode': 'MY', 'channelNumber': '306',
            'language': 'Mandarin', 'feedVariant': 'test fixture', 'broadcastType': 'television',
            'identityVerified': True, 'publicationAllowed': True,
            'identityEvidenceUrls': ['https://example.org/test-only'],
            'authorizationEvidenceUrls': ['https://example.org/test-only'],
            'approvedDocuments': ['https://example.org/test-only'], 'mediaHosts': ['media.example.org']}
        url = 'https://media.example.org/bobtv-route-recovery-test-only.m3u8'
        candidate = {'url': url, 'source': 'https://example.org/test-only', 'countryCode': 'MY', 'decoded': True}
        result = recovery.admit(target_dir, recovery.identity(payload, channel), channel['id'], [candidate], profile, int(time.time()))
        assert result['added'] == 1
        process(target_dir, limit=0)
        _, after = recovery.catalog(target_dir)
        owners = [c['id'] for c in after['channels'] if any(r['url'] == url for r in c['routes'])]
        assert owners == [channel['id']], owners
        assert {c['id'] for c in payload['channels']} <= {c['id'] for c in after['channels']}
        _, public = recovery.catalog(data)
        assert not any(r['url'] == url for c in public['channels'] for r in c['routes'])
        return {'isolatedAdmission': True, 'deployedPublisherPreserved': True,
            'sameChannelIdentityAfterRefresh': True, 'originalChannels': len(payload['channels']),
            'testChannelsAfterRefresh': len(after['channels']), 'productionCanaryRoutes': 0}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--site', type=Path, required=True)
    parser.add_argument('--staging', type=Path, required=True)
    parser.add_argument('--data', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(check(args.site, args.staging, args.data)))
