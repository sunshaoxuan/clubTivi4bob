"""Catalogue synchronization must not rewrite unchanged discovery rows."""
from contextlib import closing
import json
from pathlib import Path
import sys

import pytest

sys.path.insert(0,str(Path(__file__).parents[1]))
import epg_discovery as discovery
from epg_ingest import database


def channel(identity='one',country='CN',playable=True):
    return {'id':identity,'name':'Fixture '+identity,'epgId':identity+'.cn',
        'countryCode':country,'regionCode':None,
        'routes':[{'lastPlayableAt':'2026-10-16T00:00:00Z'}] if playable else []}


@pytest.fixture
def conn(tmp_path):
    with closing(database(tmp_path)) as value:
        discovery.sync_catalog(value,{'version':'one'},[channel('a'),channel('b')],100)
        with value:
            value.execute("UPDATE discovery_jobs SET state='review',source_generation='preserved',candidates='[]',reason='preserved',next_retry=999,lease_until=555,lease_token='lease'")
        yield value


def rows(conn):
    return [dict(row) for row in conn.execute('SELECT * FROM discovery_jobs ORDER BY channel_id')]


def test_unchanged_catalog_has_zero_row_changes_and_preserves_work(conn):
    before=rows(conn)
    changes=conn.total_changes
    discovery.sync_catalog(conn,{'version':'one'},[channel('a'),channel('b')],200)
    assert conn.total_changes==changes
    assert rows(conn)==before


def test_version_update_writes_each_row_once_without_active_toggle(conn):
    before=rows(conn)
    changes=conn.total_changes
    discovery.sync_catalog(conn,{'version':'two'},[channel('a'),channel('b')],200)
    assert conn.total_changes-changes==3
    assert rows(conn)==[{**row,'catalog_version':'two'} for row in before]


def test_priority_update_does_not_reset_audit_state_or_lease(conn):
    before=rows(conn)
    changes=conn.total_changes
    discovery.sync_catalog(conn,{'version':'one'},[channel('a',playable=False),channel('b')],200)
    assert conn.total_changes-changes==1
    assert rows(conn)==[{**before[0],'priority':1},before[1]]


def test_removed_and_reactivated_identity_preserves_existing_results(conn):
    before=rows(conn)
    changes=conn.total_changes
    discovery.sync_catalog(conn,{'version':'one'},[channel('a')],200)
    assert conn.total_changes-changes==1
    assert rows(conn)==[before[0],{**before[1],'active':0}]
    changes=conn.total_changes
    discovery.sync_catalog(conn,{'version':'one'},[channel('a'),channel('b')],201)
    assert conn.total_changes-changes==1
    assert rows(conn)==before


def test_only_changed_identity_requeues(conn):
    changed={**channel('a'),'name':'Changed name'}
    before=rows(conn)[1]
    discovery.sync_catalog(conn,{'version':'one'},[changed,channel('b')],200)
    current=rows(conn)
    assert current[1]==before
    assert current[0]['state']=='pending'
    assert current[0]['source_generation']==''
    assert current[0]['lease_until']==0
    assert current[0]['lease_token'] is None
    assert current[0]['next_retry']==0
    assert json.loads(current[0]['payload'])['name']=='Changed name'


def test_identity_preparation_occurs_outside_write_transaction(conn,monkeypatch):
    original=discovery.fingerprint
    checks=[]
    def fingerprint(value):
        checks.append(conn.in_transaction)
        return original(value)
    monkeypatch.setattr(discovery,'fingerprint',fingerprint)
    discovery.sync_catalog(conn,{'version':'one'},[channel('a'),channel('b')],200)
    assert checks==[False,False]


def test_sync_does_not_issue_per_channel_selects(conn):
    statements=[]
    conn.set_trace_callback(statements.append)
    try:
        discovery.sync_catalog(conn,{'version':'one'},[channel('a'),channel('b')],200)
    finally:
        conn.set_trace_callback(None)
    assert len([sql for sql in statements if sql.lstrip().upper().startswith('SELECT')])<=1
