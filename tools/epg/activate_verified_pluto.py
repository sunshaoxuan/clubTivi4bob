"""Operator-reviewed German Pluto cohort. Identity proof precedes publication."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import time


def main():
    p=argparse.ArgumentParser();p.add_argument('--proof',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--validate-only',action='store_true');a=p.parse_args()
    from catalog_inventory import DATA
    from epg_ingest import registry,database,probe_batch
    from epg_pluto import fetch_schedule,parse_schedule,route_id
    import epg_store as store
    import epg_discovery as discovery
    from epg_research_rounds import capture,record
    from epg_publish_worker import run as publish
    root=Path(DATA);directory=root/'epg';a.output.mkdir(parents=True,exist_ok=True)
    proof=json.loads(a.proof.read_text());source=next(s for s in registry() if s['id']=='pluto-de-official-v1');now=int(time.time())
    if a.validate_only:assert '/epg-staging/' in str(root.resolve())
    with (directory/'worker.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        conn=database(directory);discovery.migrate(conn);store.migrate(conn)
        before=capture(conn,directory,now);record(conn,directory,now,now=now,kind='verified_provider_start')
        old=[dict(r) for r in conn.execute('SELECT * FROM epg_mapping_approvals ORDER BY channel_id')]
        manifest,channels=discovery.load_catalog(root);discovery.sync_catalog(conn,manifest,channels,now)
        body,receipt=fetch_schedule(source,now);parsed=parse_schedule(body,source,now)
        targets=[]
        for evidence in proof:
            channel=next(c for c in channels if c['id']==evidence['channelId']);identity=evidence['providerChannelId'];original='pluto:de:'+identity
            assert channel['countryCode']=='DE' and evidence['countryCode']=='DE'
            assert channel['routes'] and all(route_id(r['url'])==identity for r in channel['routes'])
            assert sorted(hashlib.sha256(r['url'].encode()).hexdigest() for r in channel['routes'])==evidence['routeSha256']
            assert parsed['identityContexts'][original]['channelSlug']==evidence['officialSlug']
            assert any(p['originalChannelId']==original and p['startUtc']<=now<p['endUtc'] for p in parsed['programmes'])
            assert any(p['originalChannelId']==original and p['startUtc']>now for p in parsed['programmes'])
            targets.append(channel['id'])
        assert len(targets)==4 and len(set(targets))==4
        probe_batch(directory,[source],now,lambda _:(body,receipt))
        if store.reviewed_data_use(conn,source['id']) is None:
            store.approve_data_use(conn,source['id'],source_url=source['url'],evidence_url=source['dataLicense']['evidenceUrl'],
                data_license='Pluto TV factual schedule metadata; operator-authorized scope',programme_data_permission=True,now=now)
        for evidence in proof:
            cid=evidence['channelId'];identity=evidence['providerChannelId']
            store.approve_mapping(conn,cid,source['id'],'pluto:de:'+identity,evidence={
                'evidenceUrl':'https://pluto.tv/de/live-tv/'+evidence['officialSlug'],'countryCode':'DE','regionCode':None,
                'sourceCountryCode':'DE','sourceRegionCode':None,'sameChannelAndDelayVersion':True,
                'providerChannelId':identity,'routeSha256':evidence['routeSha256'],'identityObservedAtUtc':evidence['checkedAtUtc'],
                'identityPolicy':'official_pluto_global_feed_id_slug_market_and_exact_route_v1',
                'proofSha256':hashlib.sha256(a.proof.read_bytes()).hexdigest()},now=now)
        health=conn.execute('SELECT * FROM source_health WHERE id=?',(source['id'],)).fetchone()
        cached=conn.execute('SELECT * FROM epg_source_payloads WHERE source_id=?',(source['id'],)).fetchone();fetched_at=now
        if health['content_sha256']!=hashlib.sha256(body).hexdigest() or health['last_success']!=now:
            if cached:
                body=(directory/'payload-cache'/cached['file_name']).read_bytes();fetched_at=cached['fetched_at']
                assert hashlib.sha256(body).hexdigest()==cached['sha256']==health['content_sha256']
            else:
                assert health['state']=='healthy' and health['last_error'] is None
                with conn:
                    conn.execute('UPDATE source_health SET next_retry=? WHERE id=?',(now,source['id']))
                    conn.execute('INSERT INTO probe_audit(source_id,checked_at,state,error_code) VALUES(?,?,?,?)',
                        (source['id'],now,'mapping_bootstrap_refresh','healthy_source_new_mapping_without_payload'))
                probe_batch(directory,[source],now,lambda _:(body,receipt))
        assert store.cache_validated_payload(conn,directory,source['id'],body,fetched_at)
        ingestion=store.ingest_batch(conn,source['id'],body,targets,fetched_at=fetched_at,now=now)
        new=[dict(r) for r in conn.execute('SELECT * FROM epg_mapping_approvals ORDER BY channel_id')]
        assert [r for r in old if r['channel_id'] not in targets]==[r for r in new if r['channel_id'] not in targets]
        if a.validate_only:
            payload=store.build_payload(conn,now);ids={c['id'] for c in payload['channels']}
            result={'validationOnly':True,'candidateChannels':len(ids),'allTargetsPresent':set(targets)<=ids,
                    'sourceReceipt':receipt,'sourceQuality':parsed['quality'],'ingestion':ingestion,'unrelatedApprovalsUnchanged':True}
            assert result['allTargetsPresent'];(a.output/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result));return
        conn.close()
    publication=publish(directory);conn=database(directory);finished=int(time.time());after=capture(conn,directory,finished)
    assert after['publishedIds'] is not None and set(targets)<=set(after['publishedIds']),publication
    audit=record(conn,directory,now,now=finished,kind='verified_provider_activation',execution={
        'sourceCheckAttempts':receipt['pagesFetched'],'sourceBodiesRead':receipt['pagesFetched'],'programmeResponsesRead':receipt['pagesFetched']})
    result={'coverageBefore':before['coverage'],'coverageAfter':after['coverage'],'sourceReceipt':receipt,'sourceQuality':parsed['quality'],
            'targets':targets,'publication':publication,'round':audit,'unrelatedApprovalsUnchanged':True}
    (a.output/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result));conn.close()


if __name__=='__main__':main()
