"""Trusted operator activation of an exact reviewed Rakuten market/service route."""
import argparse,fcntl,hashlib,json,time
from pathlib import Path


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--source-id',required=True);parser.add_argument('--proof',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--validate-only',action='store_true');a=parser.parse_args()
    from catalog_inventory import DATA
    from epg_ingest import registry,database,probe_batch
    from epg_rakuten import fetch_schedule,parse_schedule
    import epg_store as store
    import epg_discovery as discovery
    from epg_research_rounds import capture,record
    from epg_publish_worker import run as publish
    root=Path(DATA);directory=root/'epg';proof=json.loads(a.proof.read_text());now=int(time.time())
    source=next(s for s in registry() if s['id']==a.source_id);assert source['format']=='rakuten-json'
    assert proof['marketCode']==source['marketCode'] and proof['hasMediaSegments']
    a.output.mkdir(parents=True,exist_ok=True)
    with (directory/'worker.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        conn=database(directory);discovery.migrate(conn);store.migrate(conn)
        before=capture(conn,directory,now);record(conn,directory,now,now=now,kind='verified_provider_start')
        old=[dict(r) for r in conn.execute('SELECT * FROM epg_mapping_approvals ORDER BY channel_id')]
        manifest,channels=discovery.load_catalog(root);discovery.sync_catalog(conn,manifest,channels,now)
        channel=next(c for c in channels if c['id']==proof['channelId'])
        assert channel['countryCode']==source['countryCode']==proof['countryCode']
        assert [hashlib.sha256(r['url'].encode()).hexdigest() for r in channel['routes']]==[proof['routeSha256']]
        body,receipt=fetch_schedule(source,now);parsed=parse_schedule(body,source,now)
        original=f"rakuten:{source['marketCode']}:{proof['serviceId']}"
        assert parsed['identityContexts'][original]['channelSlug']==proof['officialSlug']
        assert any(p['originalChannelId']==original and p['startUtc']<=now<p['endUtc'] for p in parsed['programmes'])
        probe_batch(directory,[source],now,lambda _:(body,receipt))
        store.approve_data_use(conn,source['id'],source_url=source['url'],evidence_url=source['dataLicense']['evidenceUrl'],
            data_license='Rakuten TV factual schedule metadata; operator-authorized scope',programme_data_permission=True,now=now)
        evidence={'evidenceUrl':source['dataLicense']['evidenceUrl'],'countryCode':channel['countryCode'],
            'regionCode':channel.get('regionCode'),'sourceCountryCode':source['countryCode'],'sourceRegionCode':None,
            'sameChannelAndDelayVersion':True,'providerMarketCode':source['marketCode'],'providerServiceId':proof['serviceId'],
            'routeSha256':[proof['routeSha256']],'routeObservationAtUtc':proof['checkedAtUtc'],
            'officialChannelSlug':proof['officialSlug'],'proofSha256':hashlib.sha256(a.proof.read_bytes()).hexdigest(),
            'identityPolicy':'official_market_service_slug_route_and_dated_programme_v1'}
        store.approve_mapping(conn,channel['id'],source['id'],original,evidence=evidence,now=now)
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
        ingestion=store.ingest_batch(conn,source['id'],body,[channel['id']],fetched_at=fetched_at,now=now)
        new=[dict(r) for r in conn.execute('SELECT * FROM epg_mapping_approvals ORDER BY channel_id')]
        assert [r for r in old if r['channel_id']!=channel['id']]==[r for r in new if r['channel_id']!=channel['id']]
        if a.validate_only:
            assert '/epg-staging/' in str(root.resolve())
            candidate=store.build_payload(conn,now)
            result={'validationOnly':True,'candidateChannels':len(candidate['channels']),
                'targetPresent':channel['id'] in {c['id'] for c in candidate['channels']},
                'ingestion':ingestion,'sourceQuality':parsed['quality'],'unrelatedMappingApprovalsUnchanged':True}
            (a.output/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result));conn.close();return
        conn.close()
    publication=publish(directory);conn=database(directory);finished=int(time.time());after=capture(conn,directory,finished)
    assert after['publishedIds'] is not None and channel['id'] in after['publishedIds'],publication
    audit=record(conn,directory,now,now=finished,kind='verified_provider_activation')
    result={'sourceId':source['id'],'sourceReceipt':receipt,'sourceQuality':parsed['quality'],'coverageBefore':before['coverage'],
        'coverageAfter':after['coverage'],'actuallyAddedChannelIds':sorted(set(after['publishedIds'])-set(before['publishedIds'])),
        'ingestion':ingestion,'publication':publication,'round':audit,'unrelatedMappingApprovalsUnchanged':True}
    (a.output/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False));conn.close()

if __name__=='__main__':main()
