"""Authored catalogue fixtures; no real searches, programmes or permissions."""
import gzip
import hashlib
import json
from pathlib import Path
import sys

import pytest

sys.path.insert(0,str(Path(__file__).parents[1]))
import epg_channel_research as q
import epg_channel_research_worker as worker
from epg_ingest import database, EpgError
from test_epg_channel_research import channel, facts, PATH, NOW


def run(tmp_path, channels=None, now=NOW, focus='fixture-2'):
    channels = [channel()] if channels is None else channels
    return worker.run(tmp_path,{'version':'v1'},channels,{c['id']:PATH for c in channels},now,focus_channel=focus)


def read(tmp_path, table):
    with database(tmp_path) as conn:
        return [dict(r) for r in conn.execute('SELECT * FROM '+table)]


def test_explicit_channel_identity_gate_does_not_run_legacy_provider_or_source_calls(tmp_path,monkeypatch):
    import epg_ingest, epg_source_discovery
    monkeypatch.setattr(epg_ingest,'probe_batch',lambda *a,**k:pytest.fail('no provider fetch'))
    monkeypatch.setattr(epg_source_discovery,'run',lambda *a,**k:pytest.fail('no country discovery'))
    monkeypatch.setattr(q,'claim_one',lambda *a,**k:pytest.fail('no lease without executor'))
    monkeypatch.setattr(q,'defer_without_search',lambda *a,**k:pytest.fail('no artificial postponement'))
    result=run(tmp_path,[channel(identity='unrelated'),channel()])
    assert result['selectedChannelId']=='fixture-2' and result['claimedChannels']==0
    assert result['selectedDueChannels']==1 and result['readOnlyDueSelection']
    assert not result['retryFloorsAdvancedWithoutExecution']
    assert result['state']=='pending_identity' and result['safeError']=='identity_review_required'
    assert not result['identityReviewed'] and not result['networkSearchExecutorImplemented']
    assert result['sourceNetworkRequests']==result['newMappings']==result['newGrants']==0
    assert not result['legacyCountryProviderDiscoveryEnabled'] and not result['published']
    assert read(tmp_path,'source_health')==read(tmp_path,'probe_audit')==[]
    audit=read(tmp_path,'epg_channel_research_audit')
    assert [r['event'] for r in audit]==['enqueued']
    assert len(read(tmp_path,'epg_channel_research_jobs'))==1


def test_unchanged_timer_does_not_claim_audit_or_postpone_a_real_review_floor(tmp_path):
    seed_known(tmp_path,[channel()],{'fixture-2':NOW+3600})
    first=run(tmp_path);jobs=read(tmp_path,'epg_channel_research_jobs');audit=read(tmp_path,'epg_channel_research_audit')
    second=run(tmp_path,now=NOW+60)
    assert second['claimedChannels']==0 and second['nextRetryAtUtc']==first['nextRetryAtUtc']==NOW+3600
    assert read(tmp_path,'epg_channel_research_jobs')==jobs
    assert read(tmp_path,'epg_channel_research_audit')==audit
    due=run(tmp_path,now=NOW+3600)
    assert due['claimedChannels']==0 and due['selectedDueChannels']==1
    assert due['nextRetryAtUtc']==NOW+3600
    assert read(tmp_path,'epg_channel_research_jobs')==jobs
    assert read(tmp_path,'epg_channel_research_audit')==audit
    assert run(tmp_path,now=NOW+7200)['nextRetryAtUtc']==NOW+3600
    assert read(tmp_path,'epg_channel_research_jobs')==jobs


def test_removed_catalogue_channel_preserves_history_and_cannot_be_claimed(tmp_path):
    run(tmp_path);before=read(tmp_path,'epg_channel_research_audit')
    result=run(tmp_path,[],now=NOW+1,focus=None)
    assert result['activeJobs']==result['claimedChannels']==0
    assert read(tmp_path,'epg_channel_research_audit')[:len(before)]==before
    row=read(tmp_path,'epg_channel_research_jobs')[0]
    assert not row['active'] and row['attempts']==0 and row['next_retry']==0
    with database(tmp_path) as conn:assert q.claim_one(conn,NOW+86400) is None


def test_missing_explicit_focus_never_falls_back_to_unrelated_channel(tmp_path):
    with pytest.raises(EpgError,match='research_focus_missing'):
        run(tmp_path,[channel(identity='other')])


def test_route_or_category_drift_invalidates_review_before_any_source_search(tmp_path):
    with database(tmp_path) as conn:
        q.migrate(conn);q.enqueue(conn,channel(),'old',PATH,NOW)
        target=q.claim_one(conn,NOW);q.confirm_identity(conn,target,facts(),NOW+1,explicitly_reviewed=True)
        q.record_search(conn,target,['Fixture 2 EPG'],[],'not_found',NOW+2)
    modified=channel();modified['routes'][0]['url']='https://stream.example.org/other.m3u8'
    result=run(tmp_path,[modified],NOW+10)
    assert result['state']=='pending_identity' and not result['identityReviewed']
    assert result['claimedChannels']==0 and result['selectedDueChannels']==1
    assert any(r['event']=='identity_changed' for r in read(tmp_path,'epg_channel_research_audit'))


@pytest.mark.parametrize('locked',[0,1])
def test_all_nonrevoked_mapping_approvals_are_protected_and_unchanged(tmp_path,locked):
    run(tmp_path)
    with database(tmp_path) as conn:
        conn.execute('CREATE TABLE epg_mapping_approvals(channel_id TEXT PRIMARY KEY,revoked INTEGER,locked INTEGER,evidence TEXT)')
        conn.execute('INSERT INTO epg_mapping_approvals VALUES(?,0,?,?)',('fixture-2',locked,'retained operator evidence'))
        conn.commit()
    before=read(tmp_path,'epg_mapping_approvals')
    result=run(tmp_path,now=NOW+3600)
    assert result['state']=='protected_mapping' and result['claimedChannels']==result['activeJobs']==0
    assert read(tmp_path,'epg_mapping_approvals')==before
    assert read(tmp_path,'epg_channel_research_jobs')[0]['active']==0


def test_reactivated_identity_keeps_existing_longer_retry_and_audits(tmp_path):
    seed_known(tmp_path,[channel()],{'fixture-2':NOW+3600})
    run(tmp_path,[],NOW+1,focus=None)
    result=run(tmp_path,now=NOW+2)
    assert result['activeJobs']==1 and result['claimedChannels']==0
    assert result['nextRetryAtUtc']==NOW+3600
    assert read(tmp_path,'epg_channel_research_jobs')[0]['attempts']==0


def test_switching_explicit_target_preserves_previous_case_retry_and_evidence(tmp_path):
    targets=[channel(),channel(name='Fixture Education Radio',identity='fixture-radio')]
    run(tmp_path,targets)
    old_job=read(tmp_path,'epg_channel_research_jobs')[0]
    old_audit=read(tmp_path,'epg_channel_research_audit')
    second=run(tmp_path,targets,now=NOW+60,focus='fixture-radio')
    jobs={r['channel_id']:r for r in read(tmp_path,'epg_channel_research_jobs')}
    assert jobs['fixture-2']==old_job
    assert read(tmp_path,'epg_channel_research_audit')[:len(old_audit)]==old_audit
    assert second['selectedChannelId']=='fixture-radio' and second['activeJobs']==2
    assert second['nextRetryAtUtc']==0 and second['claimedChannels']==0
    assert second['selectedDueChannels']==1
    assert not second['identityReviewed'] and second['sourceNetworkRequests']==0


def test_reviewed_identity_waits_for_executor_without_fabricated_search(tmp_path):
    with database(tmp_path) as conn:
        q.migrate(conn);q.enqueue(conn,channel(),'v1',PATH,NOW)
        target=q.claim_one(conn,NOW);q.confirm_identity(conn,target,facts(),NOW+1,explicitly_reviewed=True)
    before=read(tmp_path,'epg_channel_research_jobs')
    audits=read(tmp_path,'epg_channel_research_audit')
    result=run(tmp_path,now=NOW+3600)
    assert result['identityReviewed'] and result['state']=='search_pending'
    assert result['safeError']=='search_executor_unavailable' and result['sourceNetworkRequests']==0
    assert not any(r['event']=='search_recorded' for r in read(tmp_path,'epg_channel_research_audit'))
    assert read(tmp_path,'epg_channel_research_jobs')==before
    assert read(tmp_path,'epg_channel_research_audit')==audits


@pytest.mark.parametrize('outcome',['waiting_rights','waiting_access','waiting_validation','not_found'])
def test_missing_executor_preserves_last_actual_search_result_and_evidence(tmp_path,outcome):
    with database(tmp_path) as conn:
        q.migrate(conn);q.enqueue(conn,channel(),'v1',PATH,NOW)
        claim=q.claim_one(conn,NOW);q.confirm_identity(conn,claim,facts(),NOW+1,explicitly_reviewed=True)
        due=q.record_search(conn,claim,['Fixture Financial Channel 2 XMLTV'],
            [{'url':'https://broadcaster.example.org/epg/','result':'fixture source reviewed',
              'reason':'Fixture retained source-level review outcome'}],outcome,NOW+2)
    before=read(tmp_path,'epg_channel_research_jobs')[0]
    searches=[r for r in read(tmp_path,'epg_channel_research_audit') if r['event']=='search_recorded']
    early=run(tmp_path,now=due-1)
    assert early['claimedChannels']==0 and read(tmp_path,'epg_channel_research_jobs')[0]==before
    result=run(tmp_path,now=due)
    after=read(tmp_path,'epg_channel_research_jobs')[0]
    assert result['state']==outcome and result['safeError']==outcome
    assert result['executionSafeError']=='search_executor_unavailable'
    assert after['state']==before['state'] and after['last_error']==before['last_error']
    assert after['identity_evidence']==before['identity_evidence']
    assert after==before
    assert after['lease_token'] is None and after['lease_until']==0
    assert [r for r in read(tmp_path,'epg_channel_research_audit') if r['event']=='search_recorded']==searches
    assert result['claimedChannels']==0 and result['selectedDueChannels']==1
    assert result['readOnlyDueSelection'] and not result['retryFloorsAdvancedWithoutExecution']
    assert result['sourceNetworkRequests']==result['newMappings']==result['newGrants']==0
    again=run(tmp_path,now=after['next_retry'])
    assert again['state']==outcome and again['safeError']==outcome
    assert again['executionSafeError']=='search_executor_unavailable'
    assert [r for r in read(tmp_path,'epg_channel_research_audit') if r['event']=='search_recorded']==searches


def test_default_selects_one_priority_channel_without_country_fetch(tmp_path):
    result=run(tmp_path,[channel(identity='fr',country='FR'),channel(identity='tw',country='TW')],focus=None)
    assert result['selectedChannelId']=='tw' and result['activeJobs']==result['selectedDueChannels']==1
    assert result['claimedChannels']==0


def test_deactivation_invalidates_outstanding_claim(tmp_path):
    with database(tmp_path) as conn:
        q.migrate(conn);q.enqueue(conn,channel(),'v1',PATH,NOW);claim=q.claim_one(conn,NOW)
        q.deactivate(conn,'fixture-2',NOW+1,'catalog_channel_removed')
        with pytest.raises(EpgError,match='stale_research_claim'):
            q.confirm_identity(conn,claim,facts(),NOW+2,explicitly_reviewed=True)


def test_existing_legacy_retries_audits_source_health_and_programmes_are_not_changed(tmp_path):
    with database(tmp_path) as conn:
        conn.execute('CREATE TABLE epg_source_discovery_jobs(source_id TEXT,next_retry INTEGER)')
        conn.execute('INSERT INTO epg_source_discovery_jobs VALUES(?,?)',('legacy',NOW+99999))
        conn.execute('CREATE TABLE epg_programmes(channel_id TEXT,title TEXT)')
        conn.execute('INSERT INTO epg_programmes VALUES(?,?)',('protected','Fixture retained programme'))
        conn.commit()
    before={t:read(tmp_path,t) for t in ['epg_source_discovery_jobs','epg_programmes','source_health','probe_audit']}
    run(tmp_path)
    assert {t:read(tmp_path,t) for t in before}==before


def write_catalog(tmp_path, parent=None):
    target=channel();target['categoryId']='category-1'
    document={'version':'v1','channels':[target],'categories':[{'id':'category-1','name':'Fixture category','parentId':parent}]}
    compressed=gzip.compress(json.dumps(document).encode())
    digest=hashlib.sha256(compressed).hexdigest()
    base=tmp_path/'channel-catalog';(base/'snapshots').mkdir(parents=True)
    (base/'snapshots'/(digest+'.json.gz')).write_bytes(compressed)
    (base/'manifest.json').write_text(json.dumps({'version':'v1','channelCount':1,'sha256':digest}))
    return target


def test_real_catalogue_loader_binds_actual_category_route_and_identity(tmp_path):
    target=write_catalog(tmp_path)
    manifest, channels, paths=worker.load_targets(tmp_path)
    assert channels==[target] and paths=={'fixture-2':['Fixture category']}
    result=worker.run(tmp_path/'epg',manifest,channels,paths,NOW,focus_channel='fixture-2')
    assert result['selectedCategoryPath']==['Fixture category']


@pytest.mark.parametrize('parent',['missing','category-1'])
def test_missing_and_cyclic_categories_fail_closed(tmp_path,parent):
    write_catalog(tmp_path,parent)
    with pytest.raises(EpgError,match='invalid_research_category'):worker.load_targets(tmp_path)


def test_persistent_service_entry_point_has_no_legacy_country_discovery():
    unit=(Path(__file__).parents[1]/'deploy/bobtv-epg-source-discovery.service').read_text()
    assert '/epg_auto_search_worker.py --max-channels 3' in unit
    assert '--preferred-channel' not in unit
    assert '/epg_source_discovery.py' not in unit


def preferred_run(tmp_path, targets, now=NOW):
    return worker.run(tmp_path,{'version':'v1'},targets,{c['id']:PATH for c in targets},now,
                      preferred_channel='fixture-2')


def seed_known(tmp_path, targets, retries):
    with database(tmp_path) as conn:
        q.migrate(conn)
        for target in targets:
            q.enqueue(conn,target,'v1',PATH,NOW)
            conn.execute('UPDATE epg_channel_research_jobs SET next_retry=? WHERE channel_id=?',
                         (retries[target['id']],target['id']))
        conn.commit()


def test_preferred_cooldown_does_not_starve_other_known_due_case_or_add_unrelated_channel(tmp_path):
    preferred=channel();other=channel(identity='other');unrelated=channel(identity='unselected')
    seed_known(tmp_path,[preferred,other],{'fixture-2':NOW+7200,'other':NOW})
    before={r['channel_id']:r for r in read(tmp_path,'epg_channel_research_jobs')}
    result=preferred_run(tmp_path,[preferred,other,unrelated])
    after={r['channel_id']:r for r in read(tmp_path,'epg_channel_research_jobs')}
    assert result['selectedChannelId']=='other' and result['claimedChannels']==0
    assert result['selectedDueChannels']==1
    assert result['knownQueueOnly'] and result['selectionMode']=='known_queue_preferred_then_due'
    assert after['fixture-2']==before['fixture-2'] and set(after)==set(before)
    assert after['other']==before['other']
    assert result['sourceNetworkRequests']==0 and not result['networkSearchExecutorImplemented']


def test_all_known_cooldowns_preserve_jobs_audits_and_do_not_select_new_target(tmp_path):
    targets=[channel(),channel(identity='other')]
    seed_known(tmp_path,targets,{'fixture-2':NOW+7200,'other':NOW+3600})
    before=read(tmp_path,'epg_channel_research_jobs');audits=read(tmp_path,'epg_channel_research_audit')
    result=preferred_run(tmp_path,targets+[channel(identity='unselected')])
    assert result['claimedChannels']==0 and result['activeJobs']==2
    assert read(tmp_path,'epg_channel_research_jobs')==before
    assert read(tmp_path,'epg_channel_research_audit')==audits


def test_due_preferred_case_is_selected_before_other_known_due_case(tmp_path):
    targets=[channel(),channel(identity='aaa-other')]
    seed_known(tmp_path,targets,{'fixture-2':NOW,'aaa-other':NOW})
    before={r['channel_id']:r for r in read(tmp_path,'epg_channel_research_jobs')}
    result=preferred_run(tmp_path,targets)
    after={r['channel_id']:r for r in read(tmp_path,'epg_channel_research_jobs')}
    assert result['selectedChannelId']=='fixture-2' and result['claimedChannels']==0
    assert result['selectedDueChannels']==1
    assert after['aaa-other']==before['aaa-other']


def test_missing_preferred_case_and_conflicting_modes_fail_closed(tmp_path):
    with pytest.raises(EpgError,match='research_preferred_missing'):
        preferred_run(tmp_path,[channel(identity='other')])
    with pytest.raises(EpgError,match='conflicting_research_selection_modes'):
        worker.run(tmp_path,{'version':'v1'},[channel()],{'fixture-2':PATH},NOW,
                   focus_channel='fixture-2',preferred_channel='fixture-2')


def test_protected_preferred_mapping_is_not_claimed_and_other_known_case_can_rotate(tmp_path):
    targets=[channel(),channel(identity='other')]
    seed_known(tmp_path,targets,{'fixture-2':NOW,'other':NOW})
    with database(tmp_path) as conn:
        conn.execute('CREATE TABLE epg_mapping_approvals(channel_id TEXT PRIMARY KEY,revoked INTEGER,locked INTEGER,evidence TEXT)')
        conn.execute('INSERT INTO epg_mapping_approvals VALUES(?,0,1,?)',('fixture-2','operator preserved'))
        conn.commit()
    approvals=read(tmp_path,'epg_mapping_approvals')
    result=preferred_run(tmp_path,targets)
    assert result['selectedChannelId']=='other' and result['claimedChannels']==0
    assert result['selectedDueChannels']==1
    assert read(tmp_path,'epg_mapping_approvals')==approvals


@pytest.mark.parametrize('routes',[[{}],[{'url':None}],[{'url':''}]])
def test_bad_route_metadata_rejected_without_raw_url_logging(tmp_path,routes):
    target=channel();target['routes']=routes
    with database(tmp_path) as conn:
        q.migrate(conn)
        with pytest.raises(EpgError,match='invalid_research_route'):q.enqueue(conn,target,'v1',PATH,NOW)


@pytest.mark.parametrize('reviewed',[False,True])
def test_due_observation_never_leases_or_postpones_without_executor(tmp_path,monkeypatch,reviewed):
    with database(tmp_path) as conn:
        q.migrate(conn);q.enqueue(conn,channel(),'v1',PATH,NOW)
        if reviewed:
            claim=q.claim_one(conn,NOW)
            q.confirm_identity(conn,claim,facts(),NOW+1,explicitly_reviewed=True)
    before=read(tmp_path,'epg_channel_research_jobs')
    audits=read(tmp_path,'epg_channel_research_audit')
    monkeypatch.setattr(q,'claim_one',lambda *a,**k:pytest.fail('no claim without executor'))
    monkeypatch.setattr(q,'defer_without_search',lambda *a,**k:pytest.fail('no fake retry'))
    for offset in (3600,7200,86400):
        result=run(tmp_path,now=NOW+offset)
        assert result['selectedDueChannels']==1 and result['claimedChannels']==0
        assert result['executionSafeError']==('search_executor_unavailable' if reviewed else 'identity_review_required')
        assert read(tmp_path,'epg_channel_research_jobs')==before
        assert read(tmp_path,'epg_channel_research_audit')==audits


def test_observation_preserves_an_active_operator_lease(tmp_path):
    with database(tmp_path) as conn:
        q.migrate(conn);q.enqueue(conn,channel(),'v1',PATH,NOW)
        q.claim_one(conn,NOW)
    before=read(tmp_path,'epg_channel_research_jobs')
    audit=read(tmp_path,'epg_channel_research_audit')
    result=run(tmp_path,now=NOW+30)
    assert result['selectedDueChannels']==result['claimedChannels']==0
    assert read(tmp_path,'epg_channel_research_jobs')==before
    assert read(tmp_path,'epg_channel_research_audit')==audit
