"""Run against an isolated copy of production EPG and public catalogue only."""
import hashlib,json,os,pathlib,sys,time
root=pathlib.Path(os.environ['BOBTV_DATA_DIR']);directory=root/'epg'
from epg_ingest import registry,probe_batch,database
import epg_discovery as discovery
import epg_store as store
from epg_rakuten import fetch_schedule
from epg_coverage import summarize

source=next(s for s in registry(pathlib.Path(__file__).with_name('epg_sources.json')) if s['id']=='rakuten-uk-official-v1')
reviews=json.loads(pathlib.Path(__file__).with_name('route-candidate-review.json').read_text())
now=int(time.time());body,receipt=fetch_schedule(source,now)
conn=database(directory);discovery.migrate(conn);store.migrate(conn)
before=[dict(r) for r in conn.execute('SELECT * FROM epg_mapping_approvals ORDER BY channel_id')]
manifest,channels=discovery.load_catalog(root);byid={c['id']:c for c in channels};discovery.sync_catalog(conn,manifest,channels,now);conn.close()
probe=probe_batch(directory,[source],now,lambda _:(body,receipt));assert next(x for x in probe['sources'] if x['id']==source['id'])['state']=='healthy',next(x for x in probe['sources'] if x['id']==source['id'])['last_error']
conn=database(directory);store.approve_data_use(conn,source['id'],source_url=source['url'],evidence_url='https://www.rakuten.tv/uk/live_channels/action-rakuten-tv',data_license='Rakuten TV factual schedule metadata; operator-authorized scope',programme_data_permission=True,now=now)
approved=[];pending=[]
for item in reviews:
    if not item['approved']:
        pending.append({'channelId':item['id'],'state':item['state']});continue
    c=byid[item['id']];service=item['services'][0]
    evidence={'evidenceUrl':'https://www.rakuten.tv/uk/live_channels/'+item['officialChannelSlug'],
        'countryCode':c['countryCode'],'regionCode':c.get('regionCode'),
        'sourceCountryCode':'GB','sourceRegionCode':None,'sameChannelAndDelayVersion':True,
        'providerMarketCode':'uk','providerServiceId':service,
        'routeSha256':sorted(hashlib.sha256(r['url'].encode()).hexdigest() for r in c['routes']),
        'observedProgrammeEventId':item['scheduledEventId'],'observedMovieId':item['scheduledMovieId'],
        'routeObservationAtUtc':item['checkedAtUtc'],'identityPolicy':'exact_market_service_and_stream_programme_v1'}
    store.approve_mapping(conn,c['id'],source['id'],f'rakuten:uk:{service}',evidence=evidence,now=now)
    approved.append(c['id'])
assert 'channel-b842f9cdd43743693f77fc81' in approved
assert store.cache_validated_payload(conn,directory,source['id'],body,now)
ingested=store.ingest_batch(conn,source['id'],body,approved,fetched_at=now,now=now)
after=[dict(r) for r in conn.execute('SELECT * FROM epg_mapping_approvals ORDER BY channel_id')]
assert [r for r in before if r['channel_id'] not in approved]==[r for r in after if r['channel_id'] not in approved]
payload=store.build_payload(conn,now)
(directory/'candidate-client-payload.json').write_text(json.dumps(payload,ensure_ascii=False))
result={'stage':'isolated_production_clone','catalogVersion':manifest['version'],'sourcePagesFetched':receipt['pagesFetched'],'providerChannels':receipt['channelsFetched'],'mappedChannels':approved,'pending':pending,'ingestion':ingested,'unrelatedMappingsUnchanged':True,'coverage':summarize(conn,now),'payloadType':type(payload).__name__}
(root.parent/'clone-result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False))
