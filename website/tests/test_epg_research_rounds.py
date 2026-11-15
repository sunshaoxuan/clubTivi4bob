"""Coverage deltas count validated publication, never queue admissions."""
import json
from pathlib import Path
import sqlite3
import sys
sys.path.insert(0,str(Path(__file__).parents[1]))
import epg_research_rounds as r


def snap(ids):
    return {'publishedIds':ids,'coverage':{'publishedCurrentAndFutureChannels':len(ids) if ids is not None else 0,'publishedSnapshotVerifiedLocally':ids is not None}}


def test_round_records_added_and_removed_and_zero_gain_without_losing_history(monkeypatch,tmp_path):
    conn=sqlite3.connect(':memory:');conn.execute('CREATE TABLE epg_checkpoints(name TEXT PRIMARY KEY,value TEXT)')
    monkeypatch.setattr(r,'capture',lambda *_:snap(['kept','new']))
    first=r.record(conn,tmp_path,10,before=snap(['kept','old']),execution={'claimedChannels':200,'aiRequestsAttempted':5},now=20)
    assert first['addedPublishedChannelIds']==['new'] and first['removedPublishedChannelIds']==['old']
    assert first['netPublishedCoverageChange']==0 and first['coverageAfter']==2
    second=r.record(conn,tmp_path,21,execution={'claimedChannels':200},now=30)
    assert second['addedPublishedChannelIds']==[] and second['netPublishedCoverageChange']==0
    assert conn.execute('SELECT count(*) FROM epg_exploration_rounds').fetchone()[0]==2
    assert second['deltaAttribution']=='observed_shared_publication'


def test_unverified_snapshot_does_not_become_zero_coverage(monkeypatch,tmp_path):
    conn=sqlite3.connect(':memory:');conn.execute('CREATE TABLE epg_checkpoints(name TEXT PRIMARY KEY,value TEXT)')
    monkeypatch.setattr(r,'capture',lambda *_:snap(None))
    result=r.record(conn,tmp_path,10,before=snap(['retained']),now=20)
    assert result['coverageAfter'] is None and result['netPublishedCoverageChange'] is None
    assert not result['publishedSnapshotVerified']
