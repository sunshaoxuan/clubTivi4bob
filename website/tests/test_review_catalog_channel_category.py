import copy
import hashlib
import json
from pathlib import Path
import sqlite3
import sys

import pytest
sys.path.insert(0,str(Path(__file__).parents[1]))
from review_catalog_channel_category import correct_category

NOW=1792203000
OLD=['中国','央视'];NEW=OLD+['财经']


@pytest.fixture
def fixture():
    conn=sqlite3.connect(':memory:');conn.row_factory=sqlite3.Row
    conn.executescript('''CREATE TABLE catalog_channels(id TEXT PRIMARY KEY,metadata TEXT,group_name TEXT,profile TEXT);
      CREATE TABLE routes(digest TEXT PRIMARY KEY,name TEXT,group_name TEXT,manual_category INTEGER,
        manual_name INTEGER,deleted INTEGER,blocked INTEGER);
      CREATE TABLE catalog_channel_routes(digest TEXT PRIMARY KEY,channel_id TEXT,state TEXT);''')
    channel={'id':'fixture-2','name':'Fixture2','epgId':'Fixture2','countryCode':'CN','regionCode':None,
             'categoryId':'central','routes':[{'url':'https://stream.example.org/two.m3u8'}]}
    identity={k:channel[k] for k in ('id','name','epgId','countryCode','regionCode')}
    digest=hashlib.sha256(channel['routes'][0]['url'].encode()).hexdigest()
    conn.execute('INSERT INTO catalog_channels VALUES(?,?,?,?)',('fixture-2',json.dumps({k:v for k,v in channel.items() if k!='routes'}),' / '.join(OLD),'preserved-profile'))
    conn.execute('INSERT INTO catalog_channels VALUES(?,?,?,?)',('unrelated','{}','unrelated','unchanged'))
    conn.execute('INSERT INTO routes VALUES(?,?,?,0,0,0,0)',(digest,'Fixture2',' / '.join(NEW)))
    conn.execute('INSERT INTO catalog_channel_routes VALUES(?,?,?)',(digest,'fixture-2','assigned'));conn.commit()
    payload={'channels':[channel],'categories':[{'id':'country','name':'中国','parentId':None},{'id':'central','name':'央视','parentId':'country'}]}
    args=[conn,payload,identity,[digest],OLD,NEW,['Fixture2'],['https://broadcaster.example.org/channel2/'],NOW]
    yield args
    conn.close()


def test_one_entity_corrected_idempotently_without_identity_route_profile_or_payload_changes(fixture):
    conn,payload,*_=fixture;before=copy.deepcopy(payload)
    untouched=tuple(conn.execute("SELECT * FROM catalog_channels WHERE id='unrelated'").fetchone())
    routes=[tuple(r) for r in conn.execute('SELECT * FROM routes')]
    result=correct_category(*fixture)
    assert result['applied'] and result['changedEntities']==1 and result['epgMappingEdits']==result['routeEdits']==0
    row=conn.execute("SELECT * FROM catalog_channels WHERE id='fixture-2'").fetchone()
    assert row['group_name']=='中国 / 央视 / 财经' and row['profile']=='preserved-profile'
    assert json.loads(row['metadata'])['id']=='fixture-2' and payload==before
    assert tuple(conn.execute("SELECT * FROM catalog_channels WHERE id='unrelated'").fetchone())==untouched
    assert [tuple(r) for r in conn.execute('SELECT * FROM routes')]==routes
    audit=conn.execute('SELECT * FROM catalog_channel_metadata_review_audit').fetchone()
    assert json.loads(audit['previous_entity'])['group_name']=='中国 / 央视'
    assert not json.loads(audit['evidence'])['programmeFeedIdentityApproved']
    assert not correct_category(*fixture)['applied']
    assert conn.execute('SELECT count(*) FROM catalog_channel_metadata_review_audit').fetchone()[0]==1


@pytest.mark.parametrize('field',['id','name','epgId','countryCode','regionCode'])
def test_exact_identity_guard(fixture,field):
    fixture[1]['channels'][0][field]='changed'
    with pytest.raises(ValueError,match='category_review_identity_changed'):correct_category(*fixture)


def test_extra_or_changed_route_guard(fixture):
    fixture[1]['channels'][0]['routes'].append({'url':'https://stream.example.org/unreviewed.m3u8'})
    with pytest.raises(ValueError,match='category_review_routes_changed'):correct_category(*fixture)


@pytest.mark.parametrize('field',['manual_category','manual_name','deleted','blocked'])
def test_manual_and_retired_route_protection(fixture,field):
    conn=fixture[0];conn.execute('UPDATE routes SET '+field+'=1');conn.commit()
    with pytest.raises(ValueError,match='category_review_route_or_manual_guard'):correct_category(*fixture)
    assert conn.execute("SELECT group_name FROM catalog_channels WHERE id='fixture-2'").fetchone()[0]=='中国 / 央视'


def test_reassigned_route_guard(fixture):
    conn=fixture[0];conn.execute("UPDATE catalog_channel_routes SET channel_id='other'");conn.commit()
    with pytest.raises(ValueError,match='category_review_route_or_manual_guard'):correct_category(*fixture)


def test_changed_entity_category_guard(fixture):
    conn=fixture[0];conn.execute("UPDATE catalog_channels SET group_name='中国 / 央视 / 手工分类' WHERE id='fixture-2'");conn.commit()
    with pytest.raises(ValueError,match='category_review_entity_changed'):correct_category(*fixture)


def test_existing_category_id_reused(fixture):
    fixture[1]['categories'].append({'id':'existing-finance','name':'财经','parentId':'central'})
    correct_category(*fixture)
    metadata=json.loads(fixture[0].execute("SELECT metadata FROM catalog_channels WHERE id='fixture-2'").fetchone()[0])
    assert metadata['categoryId']=='existing-finance'


def test_no_broad_category_rewrite_or_unapproved_evidence(fixture):
    fixture[5]=['其他']
    with pytest.raises(ValueError,match='invalid_category_review'):correct_category(*fixture)


def test_private_evidence_url_rejected_before_writes(fixture):
    fixture[7]=['https://127.0.0.1/private']
    with pytest.raises(ValueError):correct_category(*fixture)


def international_fixture(args):
    args[4]=['中国','广播'];args[5]=['国际','英国','广播']
    args[1]['categories']=[{'id':'country','name':'中国','parentId':None},
                           {'id':'central','name':'广播','parentId':'country'}]
    args[0].execute("UPDATE catalog_channels SET group_name='中国 / 广播' WHERE id='fixture-2'")
    args[0].execute("UPDATE routes SET group_name='国际 / 英国 / 广播'")
    args[0].commit()


def test_original_international_geography_requires_explicit_opt_in(fixture):
    international_fixture(fixture)
    with pytest.raises(ValueError,match='invalid_category_review'):correct_category(*fixture)
    result=correct_category(*fixture,restore_inventory_geography=True)
    assert result['applied'] and result['routeEdits']==0
    row=fixture[0].execute("SELECT * FROM catalog_channels WHERE id='fixture-2'").fetchone()
    assert row['group_name']=='国际 / 英国 / 广播'
    assert json.loads(row['metadata'])['countryCode']=='CN'
    evidence=json.loads(fixture[0].execute('SELECT evidence FROM catalog_channel_metadata_review_audit').fetchone()[0])
    assert evidence['restoredOriginalInventoryGeography'] and not evidence['programmeFeedIdentityApproved']
    assert not correct_category(*fixture,restore_inventory_geography=True)['applied']


@pytest.mark.parametrize('mutation',['different_inventory','manual','different_service_kind'])
def test_geography_restore_cannot_override_original_route_or_manual_category(fixture,mutation):
    international_fixture(fixture)
    if mutation=='different_inventory':fixture[0].execute("UPDATE routes SET group_name='国际 / 法国 / 广播'")
    if mutation=='manual':fixture[0].execute('UPDATE routes SET manual_category=1')
    if mutation=='different_service_kind':fixture[5][-1]='电视'
    fixture[0].commit()
    with pytest.raises(ValueError):correct_category(*fixture,restore_inventory_geography=True)
    assert fixture[0].execute("SELECT group_name FROM catalog_channels WHERE id='fixture-2'").fetchone()[0]=='中国 / 广播'
