import copy
import json
import sqlite3
from types import SimpleNamespace

import pytest

from test_market_review_admin import catalog,load,URL
from channel_matching import Matcher,profile,_migrate_taxonomy
from market_review_admin import build_batch,apply_batch
from market_review_hold import refresh_holds,resolve_held_route,manual_category_override
from publish_channel_catalog import publish


def connect(folder):
    c=sqlite3.connect(folder/'channel_inventory.sqlite3');c.row_factory=sqlite3.Row
    return c


@pytest.fixture
def held(catalog):
    folder,digest=catalog
    _,payload=load(folder);channel=payload['channels'][0]
    queue={'reviewFindings':[{'channelId':'action','name':'Action Movies','countryCode':'US',
       'expectedIdentity':{k:channel.get(k) for k in ('id','name','epgId','countryCode','regionCode')},
       'categoryPath':['国际','美国','电视','电影']}]}
    (folder/'broadcast-market-review-queue.json').write_text(json.dumps(queue))
    with connect(folder) as conn:
        assert refresh_holds(conn,folder)==1
        conn.execute('ALTER TABLE routes ADD COLUMN checked_at INTEGER')
        conn.execute('ALTER TABLE routes ADD COLUMN logo_url TEXT')
    return folder,digest


def test_shared_persistent_guard_blocks_independent_worker_and_source_refresh_but_keeps_health(held):
    folder,digest=held
    with connect(folder) as conn:
        conn.execute("UPDATE routes SET group_name='国际 / 英国 / 电影',manual_category=1,revision=revision+1,checked_at=123,logo_url='https://example.org/logo.png' WHERE digest=?",(digest,))
        row=conn.execute('SELECT * FROM routes').fetchone()
        assert row['group_name']=='国际 / 美国 / 电影' and row['checked_at']==123
        assert row['logo_url']=='https://example.org/logo.png'
        meta,p=conn.execute('SELECT metadata,profile FROM catalog_channels').fetchone()
        meta,p=json.loads(meta),json.loads(p);meta.update(countryCode='GB',categoryId='uk',logoUrl='https://example.org/new.png');p['country']='GB'
        conn.execute('UPDATE catalog_channels SET metadata=?,profile=?,group_name=?',(json.dumps(meta),json.dumps(p),'国际 / 英国 / 电影'))
        r=conn.execute('SELECT * FROM catalog_channels').fetchone()
        assert json.loads(r['metadata'])['countryCode']==json.loads(r['profile'])['country']=='US'
        assert json.loads(r['metadata'])['logoUrl']=='https://example.org/new.png'
        assert r['group_name']=='国际 / 美国 / 电影'
        assert conn.execute('SELECT status FROM catalog_market_review_holds').fetchone()[0]=='context_changed'


@pytest.mark.parametrize('replacement',['replace','delete_insert'])
def test_replace_or_delete_recreate_same_identity_cannot_bypass_hold(held,replacement):
    folder,_=held
    with connect(folder) as conn:
        old=dict(conn.execute('SELECT * FROM catalog_channels').fetchone());m=json.loads(old['metadata']);m.update(countryCode='GB',categoryId='uk',name='Changed name');p=json.loads(old['profile']);p['country']='GB'
        if replacement=='delete_insert':conn.execute('DELETE FROM catalog_channels WHERE id=?',('action',))
        conn.execute('INSERT OR REPLACE INTO catalog_channels VALUES(?,?,?,?)',('action',json.dumps(m),'国际 / 英国 / 电影',json.dumps(p)))
        r=conn.execute('SELECT * FROM catalog_channels').fetchone()
        assert json.loads(r['metadata'])['countryCode']==json.loads(r['profile'])['country']=='US'
        assert r['group_name']=='国际 / 美国 / 电影'
        assert conn.execute('SELECT status FROM catalog_market_review_holds').fetchone()[0]=='context_changed'


def test_route_rebind_and_new_public_id_are_held_at_both_boundaries(held):
    folder,digest=held
    with connect(folder) as conn:
        conn.execute("UPDATE catalog_channel_routes SET channel_id='rebound' WHERE digest=?",(digest,))
        assert conn.execute('SELECT channel_id FROM catalog_channel_routes').fetchone()[0]=='action'
        assert conn.execute('SELECT status FROM catalog_market_review_holds').fetchone()[0]=='context_changed'
    _,payload=load(folder);payload['version']='rebound';payload['channels'][0].update(id='rebound',countryCode='GB')
    publish(payload,folder)
    _,after=load(folder);by={c['id']:c for c in after['channels']}
    assert set(by)=={'action','other'} and by['action']['countryCode']=='US'
    assert by['action']['routes'][0]['url']==URL


def test_matcher_hold_short_circuits_old_epg_source_and_cached_ai(held,monkeypatch):
    folder,digest=held
    with connect(folder) as conn:
        r=conn.execute('SELECT * FROM catalog_channels').fetchone()
        matcher=object.__new__(Matcher);matcher.conn=conn
        matcher.entities={'action':{'metadata':json.loads(r['metadata']),'profile':json.loads(r['profile']),'group':r['group_name']}}
        matcher.category_evidence={digest:['国际 / 德国 / 电影']};matcher.assignments={}
        matcher.ai_decisions={digest:{'response':'cached-country-DE'}}
        monkeypatch.setattr('channel_matching._evidence_profile',lambda *a,**k: (_ for _ in ()).throw(AssertionError('weak classifier was reached')))
        row=conn.execute('SELECT * FROM routes').fetchone()
        assert matcher.resolve(row)=='action'
        assert matcher.entities['action']['metadata']['countryCode']=='US'


def test_old_taxonomy_migration_cannot_change_held_profile_or_metadata(held,monkeypatch):
    folder,_=held
    with connect(folder) as conn:
        conn.execute('ALTER TABLE routes ADD COLUMN success_at INTEGER')
        conn.execute('CREATE TABLE catalog_migrations(name TEXT PRIMARY KEY)')
        conn.execute('CREATE TABLE catalog_ai_decisions(state TEXT,retry_at INTEGER,response TEXT,error_code TEXT)')
        source=profile('Action Movies','GB2600015OS',country='GB',url=URL)
        monkeypatch.setattr('channel_matching._evidence_profile',lambda *a,**k:(source,None))
        _migrate_taxonomy(conn,SimpleNamespace(),{'US':'美国','GB':'英国'})
        r=conn.execute('SELECT * FROM catalog_channels').fetchone()
        assert json.loads(r['metadata'])['countryCode']==json.loads(r['profile'])['country']=='US'


def test_explicit_user_classify_is_audited_and_synchronizes_category_id(held):
    folder,digest=held
    with connect(folder) as conn:
        assert manual_category_override(conn,digest,'国际 / 英国 / 电影','explicit-event-1')
        conn.execute("UPDATE routes SET group_name='国际 / 英国 / 电影',manual_category=1,revision=revision+1 WHERE digest=?",(digest,))
        h=conn.execute('SELECT * FROM catalog_market_review_holds').fetchone();entity=conn.execute('SELECT * FROM catalog_channels').fetchone()
        assert h['manual_event_id']=='explicit-event-1'
        assert json.loads(entity['metadata'])['countryCode']==json.loads(entity['profile'])['country']=='GB'
        category=json.loads(entity['metadata'])['categoryId']
        assert conn.execute("SELECT count(*) FROM catalog_market_hold_events WHERE kind='explicit_manual_category'").fetchone()[0]==1
        assert conn.execute('SELECT count(*) FROM catalog_market_verified_releases').fetchone()[0]==0
    _,payload=load(folder);payload['version']='manual'
    publish(payload,folder)
    _,after=load(folder);target=next(c for c in after['channels'] if c['id']=='action')
    assert target['countryCode']=='GB' and target['categoryId']==category


def test_official_review_has_separate_audited_unlock_and_same_transaction_publication(held):
    folder,_=held
    batch=build_batch(folder,['action'],authorization='official reviewed correction',allow_protected_shared=True)
    result=apply_batch(folder,batch)
    assert result['state']=='applied'
    with connect(folder) as conn:
        assert conn.execute('SELECT count(*) FROM catalog_market_review_holds').fetchone()[0]==0
        assert conn.execute('SELECT count(*) FROM catalog_market_verified_releases').fetchone()[0]==1
        assert conn.execute("SELECT count(*) FROM catalog_market_hold_events WHERE kind='official_market_review_released'").fetchone()[0]==1
    assert next(c for c in load(folder)[1]['channels'] if c['id']=='action')['countryCode']=='GB'


def test_context_revision_and_name_changes_do_not_unlock_geography(held):
    folder,digest=held
    with connect(folder) as conn:
        conn.execute("UPDATE routes SET name='New identity',epg_id='New.de',revision=revision+1 WHERE digest=?",(digest,))
        assert conn.execute('SELECT status FROM catalog_market_review_holds').fetchone()[0]=='context_changed'
        conn.execute("UPDATE routes SET group_name='国际 / 德国 / 电影' WHERE digest=?",(digest,))
        assert conn.execute('SELECT group_name FROM routes').fetchone()[0]=='国际 / 美国 / 电影'


def test_context_change_remains_in_queue_when_weak_indicators_disappear(held):
    folder,digest=held
    with connect(folder) as conn:
        conn.execute("UPDATE routes SET name='Changed',epg_id=NULL,revision=revision+1 WHERE digest=?",(digest,))
    _,payload=load(folder);payload['version']='changed-context'
    target=payload['channels'][0];target.update(name='Changed',epgId=None)
    target['routes'][0]['url']='https://example.org/changed.m3u8'
    publish(payload,folder)
    queue=json.loads((folder/'broadcast-market-review-queue.json').read_text())
    assert queue['persistentHoldCount']==1
    assert queue['reviewFindingCount']==1
    assert queue['reviewFindings'][0]['resolution']=='persistent_hold'


def test_worker_queue_excludes_holds_without_stopping_other_classification():
    import importlib.util
    from pathlib import Path
    spec=importlib.util.spec_from_file_location('production_taxonomy_worker',Path(__file__).with_name('catalog_taxonomy_worker.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    eligible_targets=module.eligible_targets
    base={'key':'held','manualOnly':False,'routeDigests':['x'],'currentPath':['国际','美国'],'name':'Fixture','marketReviewHeld':True}
    assert eligible_targets([base],{},123)==[]
    ordinary=dict(base,key='ordinary',marketReviewHeld=False)
    assert eligible_targets([base,ordinary],{},123)==[ordinary]
