"""Offline locked-mapping recovery acceptance. No live grants or network calls."""
import json
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_auto_search as search
import epg_auto_search_worker as worker
import epg_channel_research as queue
import epg_coverage_gaps as gaps
import epg_locked_recovery as recovery
import epg_evidence_review as review
from epg_channel_research_worker import protected_ids
from epg_ingest import database
from test_epg_auto_search import response, settings
from test_epg_schedule_worker import setup, NOW, SOURCE
import epg_schedule_worker as schedules

AT = NOW + 7200
CHANNEL = {'id': 'c0', 'name': 'Fixture 0', 'epgId': 's0', 'countryCode': 'CN',
           'regionCode': None, 'routes': []}
PATH = ['Fixture country', '广播']


@pytest.fixture
def conn(tmp_path):
    setup(tmp_path)
    schedules.run(tmp_path, now=NOW)
    schedules.run(tmp_path, now=AT)
    c = database(tmp_path)
    worker.migrate(c)
    yield c
    c.close()


def sync(c, now=AT, channels=None):
    channels = channels if channels is not None else [CHANNEL]
    return recovery.sync(c, {'version': 'fixture'}, channels, {v['id']: PATH for v in channels}, now)


def run(c, now=AT, **kwargs):
    channels = kwargs.pop('channels', [CHANNEL])
    return worker.run(c, {'version': 'fixture'}, channels, {v['id']: PATH for v in channels}, settings, None,
        max_channels=kwargs.pop('max_channels', 1), clock=lambda: now, monotonic=lambda: 0,
        transport=kwargs.pop('transport', lambda _, body: response(body, [])),
        reserve=kwargs.pop('reserve', lambda *_: None),
        checker=kwargs.pop('checker', lambda *_: pytest.fail('no candidate HTTP expected')), **kwargs)


def preserved(c):
    return {name: [tuple(r) for r in c.execute('SELECT * FROM ' + name)] for name in (
        'epg_mapping_approvals', 'epg_data_grants', 'epg_programmes', 'epg_source_payloads', 'source_health')}


def reviewed(c):
    sync(c)
    claim = queue.claim_one(c, AT)
    queue.confirm_identity(c, claim, {'fullName': 'Fixture 0', 'operator': 'Fixture Broadcaster',
        'countryCode': 'CN', 'channelNumber': '0', 'language': 'zh', 'feedVariant': 'Fixture main live',
        'categoryPath': PATH, 'evidenceUrls': ['https://fixture.example.org/channel/0']},
        AT, explicitly_reviewed=True)
    with c:
        c.execute('UPDATE epg_channel_research_jobs SET lease_token=NULL,lease_until=0,next_retry=0')


def test_expired_locked_mapping_reaches_identity_search_with_cache_and_mapping_unchanged(conn):
    before = preserved(conn)
    result = run(conn)
    assert result['lockedMappingRecovery']['admittedChannels'] == 1
    assert result['processedChannels'][0]['channelId'] == 'c0'
    assert result['processedChannels'][0]['stage'] == 'identity'
    assert not result['identityReviewed']
    assert result['aiRequestsAttempted'] == 1
    assert protected_ids(conn) == {'c0'}  # Other mapping consumers remain locked.
    assert preserved(conn) == before


def test_complete_identity_then_ordered_replacement_handoff_without_new_grant(conn):
    reviewed(conn)
    before = preserved(conn)
    for index, stage in enumerate(search.PHASES):
        now = AT + index * 8 * 86400
        gaps.run(conn, Path('.'), now, lambda *_: pytest.fail('no cached reparse'))
        result = run(conn, now, transport=lambda _, body: response(body, ['https://fixture.example.org/Fixture-0.xml']),
            checker=lambda url, _: {'url': url, 'httpStatus': 200, 'bodyBytes': 0, 'contentType': 'application/xml'})
        assert result['processedChannels'][0]['stage'] == stage
        assert result['sourceValidationHandoffs'] == 1
        assert result['newMappings'] == result['newGrants'] == result['newProgrammeRows'] == 0
    assert conn.execute('SELECT count(*) FROM epg_research_source_candidates').fetchone()[0] == 1
    assert preserved(conn) == before


def test_scope_is_idempotent_and_does_not_reset_crash_claim_or_floor(conn):
    sync(conn)
    claim = queue.claim_one(conn, AT)
    before = dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone())
    assert sync(conn, AT + 1)['admittedChannels'] == 0
    assert dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone()) == before
    assert run(conn, AT + 1)['aiRequestsAttempted'] == 0
    assert conn.execute("SELECT count(*) FROM epg_channel_research_audit WHERE event='locked_mapping_recovery_admitted'").fetchone()[0] == 1
    assert claim['lease_until'] == AT + 120


def test_shared_admission_denial_keeps_attempts_and_network_floors(conn):
    sync(conn)
    before = dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone())
    def denied(*_):
        raise search.SearchDeferred('search_budget_deferred', AT + 900)
    result = run(conn, reserve=denied)
    assert result['state'] == 'waiting_shared_admission'
    assert result['aiRequestsAttempted'] == 0
    assert dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone()) == before
    assert run(conn, AT + 1)['aiRequestsAttempted'] == 0


@pytest.mark.parametrize('mutation', [
    "UPDATE epg_mapping_approvals SET revoked=1",
    "UPDATE epg_mapping_approvals SET locked=0",
    "UPDATE epg_data_grants SET revoked=1",
    "UPDATE discovery_jobs SET identity_hash='changed'",
    "UPDATE epg_locked_recovery_jobs SET enabled=0",
    "UPDATE epg_coverage_gap_jobs SET last_checked=0",
    "UPDATE epg_coverage_gap_jobs SET state='covered'",
    "UPDATE epg_mapping_approvals SET approved_at=approved_at+1",
])
def test_changed_or_disabled_scope_cannot_claim_or_spend_quota(conn, mutation):
    sync(conn)
    expected = conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone()
    with conn:
        conn.execute(mutation)
    assert worker.claim_target(conn, expected, AT, admit=lambda: pytest.fail('must not spend quota')) is None


def test_actual_coverage_recovery_blocks_search_even_before_monitor_rechecks(conn):
    sync(conn)
    expected = conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone()
    with conn:
        conn.execute('UPDATE epg_programmes SET starts=starts+7200,stops=stops+7200')
    assert worker.claim_target(conn, expected, AT) is None
    assert sync(conn, AT + 1)['activeChannels'] == 0
    assert conn.execute('SELECT count(*) FROM epg_programmes').fetchone()[0] == 2


@pytest.mark.parametrize('kind', ['route', 'category', 'removed', 'mapping'])
def test_inflight_context_changes_reject_result_without_mutating_programmes(conn, kind):
    before = preserved(conn)
    def reload_targets():
        channel = dict(CHANNEL)
        path = PATH
        if kind == 'route':
            channel['routes'] = [{'url': 'https://fixture.example.org/different.m3u8'}]
        elif kind == 'category':
            path = ['Changed category']
        elif kind == 'mapping':
            with conn:
                conn.execute('UPDATE epg_mapping_approvals SET approved_at=approved_at+1')
        return {'version': 'changed'}, [] if kind == 'removed' else [channel], {'c0': path}
    result = run(conn, reload_targets=reload_targets)
    assert result['processedChannels'][0]['state'] == 'stale_result_rejected'
    assert preserved(conn)['epg_programmes'] == before['epg_programmes']


def test_recovery_precedes_ordinary_unmapped_search(conn):
    other = {**CHANNEL, 'id': 'aaa', 'name': 'Other fixture'}
    result = run(conn, channels=[other, CHANNEL])
    assert result['selectedChannelId'] == 'c0'


def test_normal_off_air_gap_with_future_slots_and_healthy_source_is_not_recovery(conn):
    with conn:
        conn.execute('UPDATE epg_programmes SET starts=starts+10800,stops=stops+10800')
    assert sync(conn)['activeChannels'] == 0
    assert 'c0' in recovery.research_protected_ids(conn, AT)


def test_registered_failed_source_cooldown_blocks_candidate_http(conn):
    with conn:
        conn.execute('UPDATE source_health SET last_error=?,next_retry=?', ('fixture_timeout', AT + 4000))
    request = {'stage': 'xmltv', 'domains': [], 'channelId': 'c0', 'fullName': 'Fixture 0'}
    checks = worker.checked_candidates(conn, {'candidates': [{'url': SOURCE['url']}]}, request, AT,
                                      lambda *_: pytest.fail('original failure retry is not due'))
    assert checks[0]['result'] == 'source_retry_deferred'
    assert checks[0]['sourceNextRetryAtUtc'] == AT + 4000


def test_manual_disable_survives_sync_and_all_history_is_retained(conn):
    sync(conn)
    before = preserved(conn)
    with conn:
        conn.execute('UPDATE epg_locked_recovery_jobs SET enabled=0')
    assert sync(conn, AT + 1)['activeChannels'] == 0
    assert not conn.execute('SELECT enabled FROM epg_locked_recovery_jobs').fetchone()[0]
    assert conn.execute('SELECT count(*) FROM epg_channel_research_audit').fetchone()[0] >= 2
    assert preserved(conn) == before


def test_locked_source_handoff_reaches_validator_but_never_overwrites_mapping(conn, tmp_path):
    reviewed(conn)
    run(conn, transport=lambda _, body: response(body, [SOURCE['url']]),
        checker=lambda url, _: {'url': url, 'httpStatus': 200, 'bodyBytes': 0, 'contentType': 'application/xml'})
    before = preserved(conn)
    result = review.validate_one_source(conn, tmp_path, AT + 61,
        fetcher=lambda *_: pytest.fail('reuse registered source health'), preferred_ids={'c0'})
    assert result['sourceId'] == SOURCE['id'] and result['sourceValidatorRequests'] == 0
    assert result['newMappings'] == result['newGrants'] == 0
    assert preserved(conn) == before


def test_changed_mapping_restarts_identity_and_phase_without_shortening_floor(conn):
    reviewed(conn)
    with conn:
        conn.execute('INSERT INTO epg_research_search_progress VALUES(?,?,3)',
            ('c0', worker.target_hash(CHANNEL, PATH)))
        conn.execute('UPDATE epg_channel_research_jobs SET next_retry=?', (AT + 20000,))
        conn.execute('UPDATE epg_mapping_approvals SET approved_at=approved_at+1')
    sync(conn, AT + 1)
    row = conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone()
    assert row['identity_evidence'] is None and row['state'] == 'pending_identity'
    assert row['next_retry'] == AT + 20000
    assert worker.phase(conn, row) == 0
