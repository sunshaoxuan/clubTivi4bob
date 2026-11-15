"""Apply the independently verified three-channel cohort and record real gain.

Run as bobtv with the production runtime on PYTHONPATH. No unverified candidate
or private client classification is changed. Existing unrelated approvals stay.
"""
import argparse,fcntl,hashlib,json,time
from pathlib import Path


def main():
    p=argparse.ArgumentParser();p.add_argument('--proof',type=Path,required=True);p.add_argument('--output',type=Path,required=True);args=p.parse_args()
    from catalog_inventory import DATA
    import market_review_admin as market
    import epg_discovery as discovery
    import epg_store as store
    from epg_ingest import database
    from epg_research_rounds import capture,record
    from epg_publish_worker import run as publish
    root=Path(DATA);directory=root/'epg';args.output.mkdir(parents=True,exist_ok=True)
    targets={'channel-a5b2b5ae71973b25108d979e','channel-26df487b6d80f30294ed3fba','channel-bed6cfd0cd28aa6973ad95dd'}
    proofs={r['id']:r for r in json.loads(args.proof.read_text())};now=int(time.time())
    for cid in targets:
        r=proofs[cid];movie=r['event']['movie_id']
        assert all(x.get('lastSegment',{}).get('movieId')==movie and not x['lastSegment']['ad'] for x in r['routeChecks'])
    conn=database(directory);store.migrate(conn);before=capture(conn,directory,now)
    (args.output/'before.json').write_text(json.dumps(before))
    record(conn,directory,now,now=now,kind='verified_cohort_start')
    old=[dict(r) for r in conn.execute('SELECT * FROM epg_mapping_approvals ORDER BY channel_id')];conn.close()
    with market.catalog_lock(root):
        _,_,catalog=market._load_catalog(root);current={c['id']:c for c in catalog['channels']}
        changes=[cid for cid in sorted(targets) if current[cid].get('countryCode')!='GB']
        if changes:
            batch=market.build_batch(root,changes,authorization='User requested verified EPG integration and evidence-based market correction 2026-11-16',allow_protected_shared=True)
            receipt=market.apply_batch_locked(root,batch)
            (args.output/'classification-receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2))
    with (directory/'worker.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        conn=database(directory);manifest,channels=discovery.load_catalog(root);discovery.sync_catalog(conn,manifest,channels,int(time.time()));by={c['id']:c for c in channels}
        for cid in sorted(targets):
            c=by[cid];r=proofs[cid];service=r['services'][0];assert c['countryCode']=='GB'
            proof={'evidenceUrl':'https://www.rakuten.tv/uk/live_channels/'+r['officialChannelSlug'],
                'countryCode':'GB','regionCode':None,'sourceCountryCode':'GB','sourceRegionCode':None,
                'sameChannelAndDelayVersion':True,'providerMarketCode':'uk','providerServiceId':service,
                'routeSha256':sorted(hashlib.sha256(x['url'].encode()).hexdigest() for x in c['routes']),
                'observedProgrammeEventId':r['event']['id'],'observedMovieId':r['event']['movie_id'],
                'routeObservationAtUtc':r['checkedAtUtc'],'routeProofSha256':hashlib.sha256(json.dumps(r,sort_keys=True).encode()).hexdigest(),
                'identityPolicy':'reviewed_delivery_alias_exact_service_programme_asset_v2'}
            store.approve_mapping(conn,cid,'rakuten-uk-official-v1',f'rakuten:uk:{service}',evidence=proof,now=int(time.time()))
        cache=conn.execute("SELECT * FROM epg_source_payloads WHERE source_id='rakuten-uk-official-v1'").fetchone()
        body=(directory/'payload-cache'/cache['file_name']).read_bytes();assert hashlib.sha256(body).hexdigest()==cache['sha256']
        ingested=store.ingest_batch(conn,'rakuten-uk-official-v1',body,sorted(targets),fetched_at=cache['fetched_at'],now=int(time.time()))
        after=[dict(r) for r in conn.execute('SELECT * FROM epg_mapping_approvals ORDER BY channel_id')]
        assert [r for r in old if r['channel_id'] not in targets]==[r for r in after if r['channel_id'] not in targets]
        conn.close()
    publication=publish(directory)
    conn=database(directory);finish=int(time.time());observed=capture(conn,directory,finish)
    assert observed['publishedIds'] is not None and targets <= set(observed['publishedIds']),publication
    round_receipt=record(conn,directory,now,now=finish,kind='verified_provider_activation')
    result={'startedAtUtc':now,'finishedAtUtc':finish,'coverageBefore':before['coverage'],
        'coverageAfter':observed['coverage'],'actuallyAddedChannelIds':sorted(set(observed['publishedIds'])-set(before['publishedIds'])),
        'cohort':sorted(targets),'ingestion':ingested,'publication':publication,'round':round_receipt,
        'unrelatedMappingApprovalsUnchanged':True}
    (args.output/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False));conn.close()

if __name__=='__main__':main()
