"""Activate operator-reviewed, exact-route schedule facts, with a staging mode.

The proof is an administrator input. Search results cannot invoke this tool.
Only scoped source identities and current catalogue route sets are accepted.
"""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'website'))
from catalog_inventory import DATA
import epg_discovery as discovery
from epg_ingest import database, fetch_source, parse_source, probe_batch, registry
import epg_store as store
from epg_publish_worker import run as publish


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--proof', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--validate-only', action='store_true')
    args = p.parse_args()
    proof = json.loads(args.proof.read_text())
    source = next(s for s in registry() if s['id'] == proof['sourceId'])
    assert source['format'] in ('xmltv', 'astro-json')
    allowed = (source['xmltvChannelIds'] if source['format'] == 'xmltv' else
               ['astro:my:'+str(s) for s in source['serviceIds']])
    country = source['countryCode']
    assert proof['operatorReviewed'] is True
    root = Path(DATA)
    if args.validate_only:
        assert '/epg-staging/' in str(root.resolve())
    directory, now = root / 'epg', int(time.time())
    assert 0 <= now - proof['checkedAtUtc'] < 7200
    args.output.mkdir(parents=True, exist_ok=True)
    with (directory / 'worker.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        conn = database(directory)
        discovery.migrate(conn)
        store.migrate(conn)
        manifest, channels = discovery.load_catalog(root)
        discovery.sync_catalog(conn, manifest, channels, now)
        by_id = {c['id']: c for c in channels}
        targets = proof['targets']
        assert 1 <= len(targets) <= 5
        assert len({t['channelId'] for t in targets}) == len(targets)
        old = [dict(r) for r in conn.execute('SELECT * FROM epg_mapping_approvals ORDER BY channel_id')]
        body, receipt = fetch_source(source, now)
        parsed = parse_source(source, body, now)
        assert set(parsed['channels']) <= set(allowed)
        for target in targets:
            c = by_id[target['channelId']]
            assert c['name'] == target['channelName'] and c['countryCode'] == country
            assert sorted(hashlib.sha256(r['url'].encode()).hexdigest() for r in c['routes']) == target['routeSha256']
            assert target['originalChannelId'] in allowed
            assert target.get('providerChannelName', c['name']) in parsed['channels'][target['originalChannelId']]
            if source['format'] == 'astro-json':
                assert parsed['identityContexts'][target['originalChannelId']]['channelNumber'] == target['providerChannelNumber']
            assert target['currentPictureReviewed'] is True
            rows = [r for r in parsed['programmes'] if r['originalChannelId'] == target['originalChannelId']]
            observed = target.get('checkedAtUtc', proof['checkedAtUtc'])
            assert 0 <= now-observed < 7200
            assert any(r['title'] == target['observedProgrammeTitle'] and
                       r['startUtc'] <= observed < r['endUtc'] for r in rows)
            assert any(r['startUtc'] <= now < r['endUtc'] for r in rows)
            assert any(r['startUtc'] > now for r in rows)
        health = conn.execute('SELECT * FROM source_health WHERE id=?', (source['id'],)).fetchone()
        assert health is None, 'Use the normal refresh path for an existing source'
        probe_batch(directory, [source], now, lambda _: (body, receipt))
        store.approve_data_use(conn, source['id'], source_url=source['url'],
            evidence_url=source['dataLicense']['evidenceUrl'],
            data_license=source['dataLicense']['name']+'; operator-authorized factual scope',
            programme_data_permission=True, now=now)
        ids = []
        for target in targets:
            c = by_id[target['channelId']]
            evidence = {'evidenceUrl': source['dataLicense']['evidenceUrl'],
                'countryCode': country, 'regionCode': c.get('regionCode'),
                'sourceCountryCode': country, 'sourceRegionCode': c.get('regionCode'),
                'sameChannelAndDelayVersion': True,
                'routeSha256': target['routeSha256'], 'observedAtUtc': target.get('checkedAtUtc', proof['checkedAtUtc']),
                'observedProgrammeTitle': target['observedProgrammeTitle'],
                'observation': target['observation'],
                'proofSha256': hashlib.sha256(args.proof.read_bytes()).hexdigest(),
                'identityPolicy': 'operator_reviewed_service_route_and_current_picture_v2'}
            if source['format'] == 'astro-json':
                evidence.update(routeScopeExplicitlyReviewed=True, routeScope=sorted(
                    [{'routeId': r['id'], 'urlSha256': hashlib.sha256(r['url'].encode()).hexdigest()}
                     for r in c['routes']], key=lambda r: r['routeId']))
            store.approve_mapping(conn, c['id'], source['id'], target['originalChannelId'],
                                  evidence=evidence, confidence=0.98, now=now)
            ids.append(c['id'])
        assert store.cache_validated_payload(conn, directory, source['id'], body, now)
        ingestion = store.ingest_batch(conn, source['id'], body, ids, fetched_at=now, now=now)
        new = [dict(r) for r in conn.execute('SELECT * FROM epg_mapping_approvals ORDER BY channel_id')]
        assert [r for r in old if r['channel_id'] not in ids] == [r for r in new if r['channel_id'] not in ids]
        payload = store.build_payload(conn, now)
        covered = {c.get('routeBinding', {}).get('catalogChannelId', c['id']) for c in payload['channels']}
        assert set(ids) <= covered
        result = {'validationOnly': args.validate_only, 'targets': ids,
                  'sourceQuality': parsed['quality'], 'ingestion': ingestion,
                  'unrelatedMappingsUnchanged': True}
        conn.close()
    if not args.validate_only:
        result['publication'] = publish(directory)
        assert result['publication']['state'] in ('published', 'unchanged'), result
    (args.output / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
