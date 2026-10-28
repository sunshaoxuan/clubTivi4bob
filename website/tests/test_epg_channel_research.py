"""Authored fixtures only; channel research never implies usable EPG coverage."""
import json
from pathlib import Path
import sqlite3
import sys
import pytest

sys.path.insert(0,str(Path(__file__).parents[1]))
import epg_channel_research as q
from epg_ingest import EpgError

NOW=1792201200
PATH=['Fixture country','Fixture broadcaster','Finance']


@pytest.fixture
def conn():
    value=sqlite3.connect(':memory:');value.row_factory=sqlite3.Row;q.migrate(value)
    yield value
    value.close()


def channel(name='Fixture 2',identity='fixture-2',country='CN'):
    return {'id':identity,'name':name,'countryCode':country,'regionCode':None,'epgId':'fixture2',
            'routes':[{'url':'https://stream.example.org/exact.m3u8','lastPlayableAt':'2026-10-17T00:00:00Z'}]}


def seed(conn):
    q.enqueue(conn,channel(),'catalogue-v1',PATH,NOW)
    return q.claim_one(conn,NOW)


def facts():
    return {'fullName':'Fixture Financial Channel 2','operator':'Fixture Broadcaster','countryCode':'CN',
            'channelNumber':'2','language':'zh','feedVariant':'national-main','categoryPath':PATH,
            'evidenceUrls':['https://broadcaster.example.org/channel2/']}


def test_one_claim_priority_and_no_provider_or_programme_work(conn):
    q.enqueue(conn,channel(identity='other',country='FR'),'v1',PATH,NOW)
    target=seed(conn)
    assert target['channel_id']=='fixture-2'
    assert target['state']=='pending_identity' and target['identity_evidence'] is None
    assert target['attempts']==1 and target['next_retry']==NOW+3600
    assert q.claim_one(conn,NOW)['channel_id']=='other'
    assert q.claim_one(conn,NOW) is None
    tables={r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert 'epg_programmes' not in tables and 'epg_mapping_approvals' not in tables


def test_search_cannot_precede_identity(conn):
    target=seed(conn)
    with pytest.raises(EpgError,match='research_identity_before_search'):
        q.record_search(conn,target,['Fixture 2 EPG'],[],'not_found',NOW+1)


def test_identity_then_specific_evidence_and_durable_retry(conn):
    target=seed(conn)
    q.confirm_identity(conn,target,facts(),NOW+1,explicitly_reviewed=True)
    retry=q.record_search(conn,target,['Fixture Financial Channel 2 EPG'],
        [{'url':'https://broadcaster.example.org/epg/','result':'candidate','reason':'Data-use scope unverified'}],
        'waiting_rights',NOW+2,retry_after=86400)
    assert retry==NOW+2+86400
    assert q.claim_one(conn,retry-1) is None
    resumed=q.claim_one(conn,retry)
    assert resumed['state']=='waiting_rights' and json.loads(resumed['identity_evidence'])==facts()
    audit=json.loads(conn.execute("SELECT evidence FROM epg_channel_research_audit WHERE event='search_recorded'").fetchone()[0])
    assert audit['newMappings']==audit['newGrants']==0 and audit['published'] is False


def test_unchanged_catalogue_refresh_preserves_attempt_and_retry(conn):
    target=seed(conn)
    assert q.enqueue(conn,channel(),'catalogue-v2',PATH,NOW+1) is False
    after=dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone())
    assert after==target


@pytest.mark.parametrize('field,value',[('name','Fixture 5+'),('epgId','fixture2+1'),('countryCode','TW')])
def test_identity_change_invalidates_old_claim_without_erasing_history(conn,field,value):
    target=seed(conn);changed=channel();changed[field]=value
    assert q.enqueue(conn,changed,'catalogue-v2',PATH,NOW+1)
    with pytest.raises(EpgError,match='stale_research_claim'):
        q.confirm_identity(conn,target,facts(),NOW+2,explicitly_reviewed=True)
    assert conn.execute('SELECT count(*) FROM epg_channel_research_audit').fetchone()[0]==3


def test_changed_route_invalidates_identity_but_playback_timestamp_does_not(conn):
    target=seed(conn);same=channel();same['routes'][0]['lastPlayableAt']='new observation'
    assert not q.enqueue(conn,same,'v2',PATH,NOW+1)
    same['routes'][0]['url']='https://stream.example.org/variant.m3u8'
    assert q.enqueue(conn,same,'v3',PATH,NOW+2)
    with pytest.raises(EpgError):q.confirm_identity(conn,target,facts(),NOW+3,explicitly_reviewed=True)


def test_protected_channel_is_not_queued(conn):
    assert not q.enqueue(conn,channel(),'v1',PATH,NOW,protected=True)
    assert q.claim_one(conn,NOW) is None


def test_expired_lease_and_crash_never_trigger_immediate_research_retry(conn):
    target=seed(conn)
    with pytest.raises(EpgError,match='stale_research_claim'):
        q.confirm_identity(conn,target,facts(),NOW+121,explicitly_reviewed=True)
    assert q.claim_one(conn,NOW+3599) is None
    assert q.claim_one(conn,NOW+3600)['attempts']==2


@pytest.mark.parametrize('mutation',[lambda f:f.pop('operator'),lambda f:f.update(countryCode='HK'),
    lambda f:f.update(categoryPath=['Wrong category']),lambda f:f.update(evidenceUrls=['https://127.0.0.1/private'])])
def test_identity_evidence_must_be_complete_and_target_scoped(conn,mutation):
    target=seed(conn);proof=facts();mutation(proof)
    with pytest.raises((EpgError,ValueError)):q.confirm_identity(conn,target,proof,NOW+1,explicitly_reviewed=True)


def test_no_implicit_identity_review_or_successful_epg_state(conn):
    target=seed(conn)
    with pytest.raises(EpgError):q.confirm_identity(conn,target,facts(),NOW+1)
    q.confirm_identity(conn,target,facts(),NOW+1,explicitly_reviewed=True)
    with pytest.raises(EpgError):q.record_search(conn,target,['Fixture 2'],[],'published',NOW+2)


@pytest.mark.parametrize('retry',[0,True,899,7*86400+1])
def test_retry_is_bounded_and_never_shortens_crash_floor(conn,retry):
    target=seed(conn);q.confirm_identity(conn,target,facts(),NOW+1,explicitly_reviewed=True)
    with pytest.raises(EpgError):q.record_search(conn,target,['Fixture 2'],[],'not_found',NOW+2,retry_after=retry)


def test_short_retry_keeps_existing_longer_floor_and_no_raw_route_urls(conn):
    target=seed(conn);q.confirm_identity(conn,target,facts(),NOW+1,explicitly_reviewed=True)
    assert q.record_search(conn,target,['Fixture 2 EPG'],[],'not_found',NOW+2,retry_after=900)==NOW+3600
    assert 'https://' not in target['payload'] and 'routeSha256' in json.loads(target['payload'])


def observation(conn):
    q.enqueue(conn, channel(), 'v1', PATH, NOW)
    return dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone())


def record_observation(conn, row, **kwargs):
    return q.record_identity_observation(conn, row['channel_id'], row['identity_hash'],
        [{'url': 'https://broadcaster.example.org/player/', 'result': 'partial_identity',
          'reason': 'Station label found; exact old catalogue route is not bound.'}],
        ['No stream signed query or programme rows retained.'], NOW + 1, **kwargs)


def test_partial_identity_is_durable_without_attempts_approval_or_programme_success(conn):
    row = observation(conn)
    assert record_observation(conn, row) == NOW + 1 + 21600
    after = dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone())
    assert after['attempts'] == row['attempts'] == 0
    assert after['state'] == 'pending_identity' and after['identity_evidence'] is None
    assert q.claim_one(conn, NOW + 21600) is None
    audit = json.loads(conn.execute("SELECT evidence FROM epg_channel_research_audit WHERE event='partial_identity_observation'").fetchone()[0])
    assert audit['identityApproved'] is audit['programmeSearchPerformed'] is audit['published'] is False
    assert audit['newMappings'] == audit['newGrants'] == 0


def test_partial_observation_never_shortens_existing_floor_or_changes_other_channel(conn):
    row = observation(conn)
    q.enqueue(conn, channel(identity='other'), 'v1', PATH, NOW)
    before = dict(conn.execute("SELECT * FROM epg_channel_research_jobs WHERE channel_id='other'").fetchone())
    with conn:
        conn.execute('UPDATE epg_channel_research_jobs SET next_retry=? WHERE channel_id=?', (NOW+86400, row['channel_id']))
    assert record_observation(conn, row, retry_after=900) == NOW + 86400
    assert dict(conn.execute("SELECT * FROM epg_channel_research_jobs WHERE channel_id='other'").fetchone()) == before


@pytest.mark.parametrize('mutation', ['changed_feed', 'leased', 'inactive', 'reviewed'])
def test_partial_observation_rejects_stale_or_protected_case_without_writes(conn, mutation):
    row = observation(conn)
    if mutation == 'changed_feed':
        changed = channel(name='Different edition');q.enqueue(conn, changed, 'v2', PATH, NOW)
    elif mutation == 'leased':
        q.claim_one(conn, NOW)
    elif mutation == 'inactive':
        q.deactivate(conn, row['channel_id'], NOW, 'protected_mapping')
    else:
        claim = q.claim_one(conn, NOW);q.confirm_identity(conn, claim, facts(), NOW, explicitly_reviewed=True)
    before = [tuple(r) for r in conn.execute('SELECT * FROM epg_channel_research_jobs')]
    audits = conn.execute('SELECT count(*) FROM epg_channel_research_audit').fetchone()[0]
    with pytest.raises(EpgError, match='stale_identity_observation'):
        record_observation(conn, row)
    assert before == [tuple(r) for r in conn.execute('SELECT * FROM epg_channel_research_jobs')]
    assert audits == conn.execute('SELECT count(*) FROM epg_channel_research_audit').fetchone()[0]


@pytest.mark.parametrize('retry', [True, 899, 7*86400+1])
def test_partial_observation_retry_bounds(conn, retry):
    row = observation(conn)
    with pytest.raises(EpgError, match='invalid_identity_observation'):
        record_observation(conn, row, retry_after=retry)


def test_partial_observation_rejects_private_or_signed_source_urls(conn):
    row = observation(conn)
    for url in ['https://127.0.0.1/private', 'https://broadcaster.example.org/?key=fixture']:
        with pytest.raises((EpgError, ValueError)):
            q.record_identity_observation(conn, row['channel_id'], row['identity_hash'],
                [{'url': url, 'result': 'partial', 'reason': 'Fixture only'}], ['Unconfirmed'], NOW + 1)


def completed_search(conn, claim, **kwargs):
    return q.record_expired_search_observation(conn, claim, ['Fixture Financial Channel 2 EPG'],
        [{'url': 'https://broadcaster.example.org/epg/', 'result': 'candidate',
          'reason': 'Public redistribution permission not established.'}],
        'waiting_rights', NOW + 130, completed_not_after=NOW + 90, **kwargs)


def test_completed_search_archives_after_expiry_without_renewing_or_retrying(conn):
    claim = seed(conn);q.confirm_identity(conn, claim, facts(), NOW + 1, explicitly_reviewed=True)
    q.enqueue(conn, channel(identity='other'), 'v1', PATH, NOW)
    other = dict(conn.execute("SELECT * FROM epg_channel_research_jobs WHERE channel_id='other'").fetchone())
    assert completed_search(conn, claim, retry_after=900) == NOW + 3600
    after = dict(conn.execute("SELECT * FROM epg_channel_research_jobs WHERE channel_id='fixture-2'").fetchone())
    assert after['state'] == 'waiting_rights' and after['attempts'] == 1
    assert after['lease_token'] is None and after['lease_until'] == 0
    assert json.loads(after['identity_evidence']) == facts()
    assert dict(conn.execute("SELECT * FROM epg_channel_research_jobs WHERE channel_id='other'").fetchone()) == other
    audit = json.loads(conn.execute("SELECT evidence FROM epg_channel_research_audit WHERE event='completed_search_observation'").fetchone()[0])
    assert audit['leaseRenewed'] is audit['published'] is False
    assert audit['completedNotAfter'] == NOW + 90 and audit['newMappings'] == audit['newGrants'] == 0
    before = conn.total_changes
    with pytest.raises(EpgError, match='stale_completed_search_observation'):
        completed_search(conn, claim)
    assert conn.total_changes == before


@pytest.mark.parametrize('mutation', ['identity_missing', 'changed_feed', 'inactive', 'wrong_token',
    'new_claim', 'deferred', 'still_live', 'after_expiry', 'before_identity', 'old_result'])
def test_completed_search_rejects_stale_or_unapproved_evidence_without_writes(conn, mutation):
    claim = seed(conn)
    if mutation != 'identity_missing':
        q.confirm_identity(conn, claim, facts(), NOW + 1, explicitly_reviewed=True)
    now, bound = NOW + 130, NOW + 90
    if mutation == 'changed_feed':
        q.enqueue(conn, channel(name='Different feed'), 'v2', PATH, NOW + 2)
    elif mutation == 'inactive':
        q.deactivate(conn, claim['channel_id'], NOW + 2, 'protected_mapping')
    elif mutation == 'wrong_token':
        claim = dict(claim, lease_token='unrelated')
    elif mutation == 'new_claim':
        q.claim_one(conn, NOW + 3600);now = NOW + 3730
    elif mutation == 'deferred':
        q.defer_without_search(conn, claim, 'search_executor_unavailable', NOW + 2)
    elif mutation == 'still_live': now = NOW + 100
    elif mutation == 'after_expiry': bound = NOW + 121
    elif mutation == 'before_identity': bound = NOW
    elif mutation == 'old_result': now = NOW + 121 + 7 * 86400
    before = conn.total_changes
    with pytest.raises(EpgError, match='stale_completed_search_observation'):
        q.record_expired_search_observation(conn, claim, ['Fixture 2 EPG'], [], 'waiting_rights', now,
            completed_not_after=bound)
    assert conn.total_changes == before


@pytest.mark.parametrize('source', ['https://127.0.0.1/epg', 'https://broadcaster.example.org/?key=fixture'])
def test_completed_search_keeps_source_url_guards(conn, source):
    claim = seed(conn);q.confirm_identity(conn, claim, facts(), NOW + 1, explicitly_reviewed=True)
    before = conn.total_changes
    with pytest.raises((EpgError, ValueError)):
        q.record_expired_search_observation(conn, claim, ['Fixture 2 EPG'],
            [{'url': source, 'result': 'candidate', 'reason': 'Unverified'}], 'waiting_rights', NOW + 130,
            completed_not_after=NOW + 90)
    assert conn.total_changes == before
