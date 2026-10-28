"""Offline evidence-flow regression; no real station approval or requests."""
import copy
import hashlib
import json
from pathlib import Path
import sqlite3
import sys

import pytest

sys.path.insert(0,str(Path(__file__).parents[1]))
import epg_auto_search as search
import epg_auto_search_worker as worker
import epg_channel_research as queue
import epg_evidence_review as review
import epg_route_directory as directory
from epg_ingest import EpgError
from test_epg_channel_research import NOW, PATH, channel
from test_epg_evidence_review import checked, result, packet, seed as seed_web


@pytest.fixture
def conn():
    value=sqlite3.connect(':memory:');value.row_factory=sqlite3.Row;worker.migrate(value)
    value.execute('CREATE TABLE epg_mapping_approvals(channel_id TEXT PRIMARY KEY,revoked INTEGER)')
    yield value
    value.close()


def observation(country='CN', state='exact_route_metadata'):
    return {'sourceUrl':directory.ENDPOINT,'state':state,'checkedAtUtc':NOW,
        'requestedRouteSha256':hashlib.sha256(channel()['routes'][0]['url'].encode()).hexdigest(),
        'bodySha256':'b'*64,'bodyBytes':123,
        'records':[{'name':'Fixture Brand','countrycode':country,'language':'Fixture language'}]
            if state=='exact_route_metadata' else []}


def seed(conn, value=None):
    target=channel();queue.enqueue(conn,target,'fixture',PATH,NOW)
    row=conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone()
    with conn:
        conn.execute('UPDATE epg_channel_research_jobs SET next_retry=?,attempts=3',(NOW+21600,))
        queue._audit(conn,row,NOW,'exact_route_directory_observation',observation() if value is None else value)
    return dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone())


def stored(conn):
    row=conn.execute('SELECT * FROM epg_research_evidence_reviews').fetchone()
    return row,json.loads(row['packet'])


def test_lookup_attaches_once_with_original_time_but_cannot_make_review_ready(conn):
    before=seed(conn)
    preview=review.attach_one_directory_observation(conn,NOW+1,set(),dry_run=True)
    assert preview['attachedChannels']==0 and not preview['reviewReady']
    assert conn.execute('SELECT count(*) FROM epg_research_evidence_reviews').fetchone()[0]==0
    value=review.attach_one_directory_observation(conn,NOW+1,set())
    assert value['attachedChannels']==1 and not value['reviewReady'] and not value['identityApproved']
    row,evidence=stored(conn)
    assert row['state']=='needs_identity_evidence' and evidence['pages']==[]
    lookup=evidence['routeDirectoryObservations'][0]
    assert lookup['checkedAtUtc']==NOW and not lookup['fieldQuotationEvidence'] and not lookup['routeApprovalEvidence']
    assert review.pending(conn,NOW+1) is None
    assert dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone())==before
    assert review.attach_one_directory_observation(conn,NOW+2,set())['attachedChannels']==0


@pytest.mark.parametrize('state',['no_exact_route_metadata','bounded_directory_check_failed'])
def test_negative_or_failed_lookup_never_becomes_success(conn,state):
    seed(conn,observation(state=state))
    value=review.attach_one_directory_observation(conn,NOW+1,set())
    assert value['lookupState']==state and not value['reviewReady']
    row,evidence=stored(conn)
    assert evidence['routeDirectoryObservations'][0]['records']==[] and row['state']!='pending'
    assert review.search_hint(conn,conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone(),NOW+1)['directoryMetadataNames']==[]


@pytest.mark.parametrize('mutation',[
    lambda value:value.update(sourceUrl='https://unverified.example.org/api'),
    lambda value:value.update(requestedRouteSha256='c'*64),
    lambda value:value.update(checkedAtUtc=NOW-21601),
    lambda value:value.update(bodySha256='invalid'),
    lambda value:value.update(records=[{'name':'Other','homepage':'https://private.invalid/'}]),
    lambda value:value.update(records=[{'name':'bad\nlabel'}]),
])
def test_wrong_route_stale_or_untyped_metadata_is_not_attached(conn,mutation):
    value=observation();mutation(value);seed(conn,value)
    assert review.attach_one_directory_observation(conn,NOW,set())['attachedChannels']==0


@pytest.mark.parametrize('guard',['protected','leased','inactive','identity_changed','manual_observation'])
def test_protected_active_or_newer_operator_decisions_survive(conn,guard):
    before=seed(conn)
    with conn:
        if guard=='protected':conn.execute('INSERT INTO epg_mapping_approvals VALUES(?,0)',(before['channel_id'],))
        elif guard=='leased':conn.execute('UPDATE epg_channel_research_jobs SET lease_until=?',(NOW+120,))
        elif guard=='inactive':conn.execute('UPDATE epg_channel_research_jobs SET active=0')
        elif guard=='identity_changed':conn.execute("UPDATE epg_channel_research_jobs SET identity_hash=?",('c'*64,))
        else:queue._audit(conn,before,NOW+1,'partial_identity_observation',{'operator':'new exclusion'})
    after=dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone())
    from epg_channel_research_worker import protected_ids
    assert review.attach_one_directory_observation(conn,NOW+1,protected_ids(conn))['attachedChannels']==0
    assert dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone())==after


def test_named_directory_metadata_can_supply_search_words_but_not_facts(conn):
    row=seed(conn);review.attach_one_directory_observation(conn,NOW,set())
    hint=review.search_hint(conn,row,NOW)
    request=search.plan(channel(),PATH,None,0,review_hint=hint)
    assert channel()['name'] in request['query'] and 'Fixture Brand' in request['query']
    assert request['stage']=='identity' and 'Do not research EPG' in request['body']['instructions']
    assert review.search_hint(conn,row,NOW+21601)['directoryMetadataNames']==[]


def test_country_conflict_blocks_existing_ready_packet_and_decode_even_with_all_web_quotes(conn):
    seed_web(conn)
    row=conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone()
    with conn:queue._audit(conn,row,NOW,'exact_route_directory_observation',observation(country='RU'))
    value=review.attach_one_directory_observation(conn,NOW,set())
    assert not value['reviewReady'] and review.pending(conn,NOW) is None
    _,evidence=stored(conn)
    with pytest.raises(EpgError,match='directory_country_conflict'):
        review.decode_review(result(),evidence,NOW)
    # An unresolved identity conflict cannot become approval merely because
    # the directory cache ages out while the checked web page remains fresh.
    with pytest.raises(EpgError,match='directory_country_conflict'):
        review.decode_review(result(),evidence,NOW+21601)
    assert review.search_hint(conn,row,NOW+21601)['directoryCountryConflict']
    hint=review.search_hint(conn,row,NOW)
    assert hint['directoryCountryConflict'] and not hint['directoryMetadataNames']
    assert 'country exact stream identity conflict' in search.plan(channel(),PATH,None,0,review_hint=hint)['query']


def test_later_web_search_preserves_directory_context_and_keeps_raw_route_gate(conn):
    before=seed(conn);review.attach_one_directory_observation(conn,NOW,set())
    claim=review.claim_review(conn,before,NOW+1,set())
    check=checked();check['linkedRouteSha256']=[]
    assert review.stage_identity(conn,claim,search.plan(channel(),PATH,None,0),{'technicalChecks':[check]},NOW+1) is False
    _,evidence=stored(conn)
    assert evidence['routeDirectoryObservations'][0]['records'] and not evidence['pages'][0]['linkedRouteSha256']
    with pytest.raises(EpgError,match='exact_route_required'):
        review.decode_review(result(),evidence,NOW+1)


def test_no_web_result_does_not_erase_directory_observation(conn):
    before=seed(conn);review.attach_one_directory_observation(conn,NOW,set())
    claim=review.claim_review(conn,before,NOW+1,set())
    assert review.stage_identity(conn,claim,search.plan(channel(),PATH,None,0),{'technicalChecks':[]},NOW+1) is None
    assert stored(conn)[1]['routeDirectoryObservations'][0]['records']


def test_worker_attaches_cached_lookup_during_model_wait_without_ai_or_job_mutation(conn):
    before=seed(conn)
    worker.control(conn,NOW,'search_budget_deferred',NOW+3600)
    value=worker.run(conn,{'version':'fixture'},[channel()],{channel()['id']:PATH},
        lambda:pytest.fail('no AI config during shared wait'),None,clock=lambda:NOW,monotonic=lambda:0)
    assert value['routeDirectoryEvidence']['attachedChannels']==1 and value['aiRequestsAttempted']==0
    assert dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone())==before
