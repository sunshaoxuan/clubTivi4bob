import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parents[1]))
from catalog_inventory import ingest, ingest_events, database
from process_channel_inventory import process
from test_shared_catalog_events import snapshot

URLS=['https://media.example.org/a.m3u8','https://media.example.org/b.m3u8',
      'https://media.example.org/c.m3u8']

def seed(path):
    ingest([{'url':url,'name':name,'group':group,'source':'test','blocked':False}
            for url,name,group in zip(URLS,['News One','News Alias','Third'],
             ['国际 / 美国 / 新闻','国际 / 美国 / 综合','国际 / 英国 / 新闻'])], 'a'*64,path)
    process(path,verifier=lambda _:True)

def merge(n=1, urls=None, revision=0, **values):
    return {'id':format(n,'032x'),'kind':'merge','url':URLS[0],
            'mergeId':'c4b64e12-61ed-4b54-985d-41011fefb948',
            'name':'Unified News','group':'国际 / 美国 / 新闻','epgId':'NEWS',
            'routes':[{'url':url,'baseRevision':revision} for url in (urls or URLS[:2])],**values}

def test_merge_is_atomic_idempotent_and_published(tmp_path):
    seed(tmp_path)
    first=ingest_events([merge()],'b'*64,tmp_path)
    assert first['receipts'][0]['status']=='applied'
    assert ingest_events([merge()],'b'*64,tmp_path)==first
    process(tmp_path,limit=0)
    data=snapshot(tmp_path)
    channel=next(c for c in data['channels'] if c['name']=='Unified News')
    assert len(channel['routes'])==2
    assert {r['url'] for r in channel['routes']}==set(URLS[:2])
    assert channel['mergeId']==merge()['mergeId']
    assert channel['epgId']=='NEWS'
    assert all(r['revision']==1 for r in channel['routes'])
    assert len(data['channels'])==2

def test_stale_merge_changes_no_member(tmp_path):
    seed(tmp_path)
    ingest_events([{'id':'2'*32,'url':URLS[1],'kind':'classify',
                   'group':'国际 / 美国 / 娱乐','baseRevision':0}],'c'*64,tmp_path)
    receipt=ingest_events([merge()],'b'*64,tmp_path)['receipts'][0]
    assert receipt['status']=='conflict'
    with database(tmp_path) as conn:
        assert conn.execute('SELECT count(*) FROM routes WHERE manual_name=1').fetchone()[0]==0

def test_retired_route_is_not_restored_and_health_is_preserved(tmp_path):
    seed(tmp_path)
    ingest_events([{'id':'3'*32,'url':URLS[0],'kind':'health','success':2},
                   {'id':'4'*32,'url':URLS[1],'kind':'retire'}],'b'*64,tmp_path)
    event=merge();event['routes'][1]['baseRevision']=1
    assert ingest_events([event],'c'*64,tmp_path)['receipts'][0]['status']=='applied'
    with database(tmp_path) as conn:
        assert conn.execute('SELECT blocked FROM routes WHERE url=?',(URLS[1],)).fetchone()[0]==1
        assert conn.execute('SELECT success_votes FROM routes WHERE url=?',(URLS[0],)).fetchone()[0]==2
    process(tmp_path,limit=0)
    assert URLS[1] not in {r['url'] for c in snapshot(tmp_path)['channels'] for r in c['routes']}

def test_old_discovery_and_old_client_cannot_undo_merge(tmp_path):
    seed(tmp_path)
    ingest_events([merge()],'b'*64,tmp_path)
    ingest_events([{'id':'5'*32,'url':URLS[0],'kind':'upsert','baseRevision':1,
      'metadata':{'name':'Old Name','group':'中国 / 北京','source':'old','epgId':'WRONG'}}], 'c'*64,tmp_path)
    with database(tmp_path) as conn:
        row=conn.execute('SELECT name,group_name,epg_id FROM routes WHERE url=?',(URLS[0],)).fetchone()
        assert tuple(row)==('Unified News','国际 / 美国 / 新闻','NEWS')

def test_partial_prior_merge_is_rejected_without_splitting(tmp_path):
    seed(tmp_path)
    ingest_events([merge()],'b'*64,tmp_path)
    event=merge(2,urls=[URLS[0],URLS[2]])
    event['routes'][0]['baseRevision']=1
    assert ingest_events([event],'c'*64,tmp_path)['receipts'][0]['status']=='conflict'

def test_invalid_or_duplicate_members_write_nothing(tmp_path):
    seed(tmp_path)
    for n,event in enumerate([merge(urls=[URLS[0],URLS[0]]),
                              merge(urls=[URLS[0],'http://127.0.0.1/private'])],10):
        event['id']=format(n,'032x')
        assert ingest_events([event],'b'*64,tmp_path)['receipts'][0]['status']=='rejected'
    with database(tmp_path) as conn:
        assert conn.execute('SELECT count(*) FROM routes WHERE merge_id IS NOT NULL').fetchone()[0]==0

def test_unknown_member_can_retry_after_inventory_arrives(tmp_path):
    seed(tmp_path)
    unknown='https://media.example.org/new.m3u8'
    event=merge(urls=[URLS[0],unknown])
    assert ingest_events([event],'b'*64,tmp_path)['receipts'][0]['status']=='retry'
    ingest([{'url':unknown,'name':'New Alias','group':'国际 / 美国 / 综合',
             'source':'test','blocked':False}], 'a'*64,tmp_path)
    process(tmp_path,verifier=lambda _:True)
    assert ingest_events([event],'b'*64,tmp_path)['receipts'][0]['status']=='applied'
