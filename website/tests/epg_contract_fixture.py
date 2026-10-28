"""Emit authored test data through the real Python publisher, with zero network.

All permissions, identities, programmes and activations exist only in a fresh
temporary database. This fixture is never a source of production EPG data.
"""
import base64
from contextlib import closing
import json
from pathlib import Path
import sys
import tempfile

sys.path[:0]=[str(Path(__file__).parents[1]),str(Path(__file__).parent)]
from test_epg_store import CHANNEL,NOW,SOURCE,licensed_grant,xml
import epg_discovery as discovery
import epg_ingest as ingest
import epg_store as store


def build_contract():
    with tempfile.TemporaryDirectory(prefix='bobtv-epg-contract-fixture-') as directory:
        base=Path(directory)
        ingest.probe_batch(base/'epg',[SOURCE],NOW,lambda _: (xml(),{}))
        with closing(ingest.database(base/'epg')) as conn:
            discovery.sync_catalog(conn,{'version':'authored-contract-fixture'},[CHANNEL],NOW)
            store.migrate(conn)
            licensed_grant(conn)
            versions=[]
            checks=[]
            def simulated_node_read(url):
                checks.append(url)
                return (base/'public/snapshots'/url.rsplit('/',1)[-1]).read_bytes()
            for index,title in enumerate(('Fixture version one','Fixture version two')):
                now=NOW+index*900
                body=xml(title)
                if index:
                    ingest.probe_batch(base/'epg',[SOURCE],now,lambda _: (body,{}))
                store.ingest_batch(conn,'fixture',body,[CHANNEL['id']],fetched_at=now,now=now)
                published=store.publish(conn,base/'public',now=now,node_fetcher=simulated_node_read)
                assert published['changed'] is True
                manifest=store.active_manifest(conn)
                compressed=(base/'public/snapshots'/(manifest['sha256']+'.json.gz')).read_bytes()
                versions.append({'checkedAtUtc':now,'manifest':manifest,
                    'compressedBase64':base64.b64encode(compressed).decode(),
                    'expectedTitles':[title,'Next fixture']})
            unchanged=store.publish(conn,base/'public',now=NOW+900,node_fetcher=simulated_node_read)
            assert unchanged['changed'] is False
            assert len(checks)==4
            assert conn.execute('SELECT count(*) FROM epg_publication_audit').fetchone()[0]==2
        return {'schemaVersion':1,'fixtureOnly':True,
            'notice':'Authored test programmes and test-only grants, never real broadcast schedules or production permissions.',
            'generator':'website/tests/epg_contract_fixture.py',
            'networkRequests':0,'simulatedNodeSnapshotChecks':len(checks),
            'temporaryDatabasePublications':2,'productionPublications':0,
            'unchangedPublicationReused':True,'catalogIdentity':{
                key:CHANNEL.get(key) for key in ('id','name','epgId','countryCode','regionCode')},
            'versions':versions}


if __name__=='__main__':
    print(json.dumps(build_contract(),ensure_ascii=False,indent=2))
