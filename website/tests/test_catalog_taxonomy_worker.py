import hashlib
import json
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).parents[1]))
import pytest
import catalog_taxonomy_worker as worker
from catalog_inventory import database
from publish_channel_catalog import publish


def test_queue_prioritizes_unknown_and_preserves_manual_and_recent_review():
    def target(key,path,**extra):
        return dict(key=key,name='Station',currentPath=path,manualOnly=False,routeDigests=[key],**extra)
    targets=[target('known',['国际','美国','电视']),target('pending',['其他']),
             {**target('manual',['其他']),'manualOnly':True}, target('reviewed',['其他'])]
    queue=worker.eligible_targets(targets,{'reviewed':{'status':'needs_review','time':100}},101)
    assert [item['key'] for item in queue]==['pending','known']


@pytest.fixture
def setup_worker(tmp_path,monkeypatch):
    url='https://media.example.org/radio.m3u8';digest=hashlib.sha256(url.encode()).hexdigest()
    key=worker.audit.stable_key([digest])
    payload={'schemaVersion':1,'version':'before','categories':[dict(id='other',name='其他',parentId=None,sortOrder=0)],'channels':[
        dict(id='station',name='Example Radio',categoryId='other',countryCode=None,regionCode=None,sortOrder=0,epgId='exact-guide',logoUrl=None,
             routes=[dict(id='route',url=url,source='fixture',lastPlayableAt=None,healthScore=.8)])]}
    manifest=publish(payload,tmp_path)
    with database(tmp_path) as conn:
        conn.execute('INSERT INTO routes(digest,name,url,group_name,source,received) VALUES(?,?,?,?,?,?)',(digest,'Example Radio',url,'其他','fixture',1))
    target=dict(key=key,name='Example Radio',currentPath=['其他'],manualOnly=False,manualCount=0,routeDigests=[digest],routeCount=1)
    monkeypatch.setattr(worker.audit,'collect_targets',lambda data:(manifest,[target]))
    monkeypatch.setattr(worker.audit,'audit_settings',lambda:{'model':'fixture-model'})
    result=dict(key=key,channel='Example Radio',oldPath=['其他'],routeDigests=[digest],status='classified',newPath=['国际','英国','广播'],confidence=.99)
    monkeypatch.setattr(worker.audit,'classify_batch',lambda *args:[result])
    return tmp_path,payload,result,digest


def test_one_batch_applies_review_without_changing_identity_routes_or_epg(setup_worker):
    data,before,result,digest=setup_worker
    status=worker.run(data)
    assert status['applied']==1 and status['reviewed']==1
    _,after,cats=worker.audit.load_catalog(data)
    original=before['channels'][0];updated=after['channels'][0]
    assert {k:v for k,v in original.items() if k!='categoryId'}=={k:v for k,v in updated.items() if k!='categoryId'}
    assert worker.audit.group_path(updated['categoryId'],cats)==['国际','英国','广播']
    with database(data) as conn:
        assert conn.execute('SELECT group_name FROM routes WHERE digest=?',(digest,)).fetchone()[0]=='国际 / 英国 / 广播'
    assert worker.run(data)['state']=='idle'


def test_manual_edit_during_inference_is_preserved(setup_worker,monkeypatch):
    data,before,result,digest=setup_worker
    def classify(*args):
        with database(data) as conn:
            conn.execute('UPDATE routes SET manual_category=1,revision=revision+1 WHERE digest=?',(digest,))
        return [result]
    monkeypatch.setattr(worker.audit,'classify_batch',classify)
    assert worker.run(data)['applied']==0
    assert worker.audit.load_catalog(data)[1]['channels']==before['channels']


def test_uncertain_decisions_remain_in_other(setup_worker):
    data,before,result,digest=setup_worker
    result.update(status='needs_review',newPath=None,confidence=.5)
    status=worker.run(data)
    assert status['applied']==0 and status['needsReview']==1
    assert worker.audit.load_catalog(data)[1]['channels']==before['channels']


def test_publication_failure_rolls_back_manifest_and_route_groups(setup_worker,monkeypatch):
    data,before,result,digest=setup_worker
    manifest=data/'channel-catalog/manifest.json';saved=manifest.read_bytes()
    def fail(*args):
        manifest.write_text('broken')
        raise RuntimeError('fixture failure')
    monkeypatch.setattr(worker,'publish',fail)
    with pytest.raises(RuntimeError):worker.run(data)
    assert manifest.read_bytes()==saved
    with database(data) as conn:
        assert conn.execute('SELECT group_name FROM routes WHERE digest=?',(digest,)).fetchone()[0]=='其他'
