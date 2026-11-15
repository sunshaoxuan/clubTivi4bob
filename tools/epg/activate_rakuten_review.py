"""Apply independently reviewed exact Rakuten routes using existing admin APIs.

Run as the service user with BOBTV_DATA_DIR. No source enumeration is approved.
"""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import time
from datetime import datetime


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reviews',type=Path,required=True)
    args=parser.parse_args()
    from catalog_inventory import DATA
    import epg_discovery as discovery
    import epg_store as store
    from epg_ingest import database,registry,probe_batch
    from epg_rakuten import fetch_schedule
    directory=Path(DATA)/'epg';now=int(time.time())
    reviews=json.loads(args.reviews.read_text())
    source=next(s for s in registry() if s['id']=='rakuten-uk-official-v1')
    body,receipt=fetch_schedule(source,now)
    with (directory/'worker.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        conn=database(directory);discovery.migrate(conn);store.migrate(conn)
        manifest,channels=discovery.load_catalog(DATA);byid={c['id']:c for c in channels}
        discovery.sync_catalog(conn,manifest,channels,now)
        probe=probe_batch(directory,[source],now,lambda _:(body,receipt))
        assert probe['sources'][0]['state']=='healthy'
        store.approve_data_use(conn,source['id'],source_url=source['url'],
            evidence_url='https://www.rakuten.tv/uk/live_channels/action-rakuten-tv',
            data_license='Rakuten TV factual schedule metadata; operator-authorized scope',
            programme_data_permission=True,now=now)
        approved=[];pending=[]
        for item in reviews:
            if not item['approved']:
                pending.append({'channelId':item['id'],'state':item['state']});continue
            assert 0 <= now-int(datetime.fromisoformat(item['checkedAtUtc']).timestamp()) < 3600
            channel=byid[item['id']];service=item['services'][0]
            assert channel['countryCode']=='GB' and len(item['services'])==1
            evidence={'evidenceUrl':'https://www.rakuten.tv/uk/live_channels/'+item['officialChannelSlug'],
                'countryCode':'GB','regionCode':channel.get('regionCode'),'sourceCountryCode':'GB',
                'sourceRegionCode':None,'sameChannelAndDelayVersion':True,
                'providerMarketCode':'uk','providerServiceId':service,
                'routeSha256':sorted(hashlib.sha256(r['url'].encode()).hexdigest() for r in channel['routes']),
                'observedProgrammeEventId':item['scheduledEventId'],'observedMovieId':item['scheduledMovieId'],
                'routeObservationAtUtc':item['checkedAtUtc'],'identityPolicy':'exact_market_service_and_stream_programme_v1'}
            store.approve_mapping(conn,channel['id'],source['id'],f'rakuten:uk:{service}',evidence=evidence,now=now)
            approved.append(channel['id'])
        assert approved
        assert store.cache_validated_payload(conn,directory,source['id'],body,now)
        ingested=store.ingest_batch(conn,source['id'],body,approved,fetched_at=now,now=now)
        result={'checkedAtUtc':now,'catalogVersion':manifest['version'],'sourceReceipt':receipt,
            'mappedChannels':approved,'pending':pending,'ingestion':ingested}
        with conn:conn.execute('INSERT OR REPLACE INTO epg_checkpoints VALUES(?,?)',('rakuten_adapter_activation',json.dumps(result)))
        conn.close();print(json.dumps(result))

if __name__=='__main__':main()
