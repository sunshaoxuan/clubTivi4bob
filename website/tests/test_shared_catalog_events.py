import gzip
import json
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parents[1]))
from catalog_inventory import ingest, ingest_events, database
from process_channel_inventory import process

URL='https://media.example.org/news.m3u8'

def event(kind, n=1, **values):
    return {'id':format(n,'032x'),'kind':kind,'url':URL,**values}

def seed(path):
    ingest([{'url':URL,'name':'NRBTV','group':'国际 / 美国 / 宗教','source':'test','blocked':False}], 'a'*64,path)
    process(path,verifier=lambda _:True)

def snapshot(path):
    manifest=json.loads((path/'channel-catalog/manifest.json').read_text())
    return json.loads(gzip.decompress((path/'channel-catalog/snapshots'/f"{manifest['sha256']}.json.gz").read_bytes()))

def test_idempotent_positive_negative_weights(tmp_path):
    seed(tmp_path)
    baseline=snapshot(tmp_path)['channels'][0]['routes'][0]['healthScore']
    events=[event('health',success=2),event('health',2,failure=1)]
    first=ingest_events(events,'b'*64,tmp_path)
    assert ingest_events(events,'b'*64,tmp_path)==first
    with database(tmp_path) as conn:
        row=conn.execute('SELECT success_votes,failure_votes FROM routes').fetchone()
        assert tuple(row)==(2,1)
    process(tmp_path,verifier=lambda _:True)
    assert snapshot(tmp_path)['channels'][0]['routes'][0]['healthScore'] != baseline

def test_success_raises_and_manual_skip_lowers_shared_weight(tmp_path):
    seed(tmp_path)
    baseline=snapshot(tmp_path)['channels'][0]['routes'][0]['healthScore']
    ingest_events([event('health',success=1)],'b'*64,tmp_path)
    process(tmp_path,limit=0)
    rewarded=snapshot(tmp_path)['channels'][0]['routes'][0]['healthScore']
    assert rewarded>baseline
    ingest_events([event('health',2,failure=1)],'b'*64,tmp_path)
    process(tmp_path,limit=0)
    assert snapshot(tmp_path)['channels'][0]['routes'][0]['healthScore']<rewarded

def test_classification_cas_and_stale_inventory(tmp_path):
    seed(tmp_path)
    receipt=ingest_events([event('classify',group='国际 / 美国 / 新闻',baseRevision=0)],'b'*64,tmp_path)
    assert receipt['receipts'][0]['revision']==1
    assert ingest_events([event('classify',2,group='中国 / 北京',baseRevision=0)],'c'*64,tmp_path)['receipts'][0]['status']=='conflict'
    ingest([{'url':URL,'name':'NRBTV','group':'中国 / 北京','source':'old','blocked':False}], 'd'*64,tmp_path)
    process(tmp_path,verifier=lambda _:True)
    data=snapshot(tmp_path)
    assert any(c['name']=='新闻' for c in data['categories'])
    assert data['channels'][0]['routes'][0]['revision']==1
    assert all(c['name']!='北京' for c in data['categories'])

def test_last_route_deletion_publishes_empty_catalog(tmp_path):
    seed(tmp_path)
    ingest_events([event('delete')],'b'*64,tmp_path)
    assert process(tmp_path,verifier=lambda _:True)['published']
    assert snapshot(tmp_path)['channels']==[]
    assert snapshot(tmp_path)['categories']==[]
    ingest([{'url':URL,'name':'NRBTV','group':'其他','source':'old','blocked':False}], 'c'*64,tmp_path)
    process(tmp_path,verifier=lambda _:True)
    assert snapshot(tmp_path)['channels']==[]

def test_unknown_health_is_retry_and_private_url_rejected(tmp_path):
    assert ingest_events([event('health',success=1)],'a'*64,tmp_path)['receipts'][0]['status']=='retry'
    e=event('delete',2); e['url']='http://127.0.0.1/private'
    assert ingest_events([e],'a'*64,tmp_path)['receipts'][0]['status']=='rejected'

def test_new_route_requires_server_verification(tmp_path):
    e=event('upsert',metadata={'name':'NRBTV','group':'国际 / 美国 / 宗教','source':'github'})
    assert ingest_events([e],'a'*64,tmp_path)['receipts'][0]['status']=='applied'
    assert not process(tmp_path,verifier=lambda _:False)['published']
