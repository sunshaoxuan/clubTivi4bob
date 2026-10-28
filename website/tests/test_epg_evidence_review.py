"""Authored identity/guide fixtures; no production approvals or network calls."""
import copy
import hashlib
import json
from pathlib import Path
import sqlite3
import sys

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_auto_search as search
import epg_auto_search_worker as worker
import epg_channel_research as queue
import epg_evidence_review as review
from epg_ingest import EpgError, database
from test_epg_auto_search import settings, response, run, rows, Page
from test_epg_channel_research import NOW, PATH, channel

URL = 'https://broadcaster.example.org/channel/fixture2'
ROUTE = 'https://stream.example.org/exact.m3u8'
ROUTE_HASH = hashlib.sha256(ROUTE.encode()).hexdigest()
VALUES = {'fullName': 'Fixture 2', 'operator': 'Fixture Broadcaster', 'countryCode': 'CN',
          'channelNumber': 'Frequency 92.1', 'language': 'zh', 'feedVariant': 'Fixture National live'}
TEXT = 'Fixture 2. Fixture Broadcaster. Country CN. Frequency 92.1. Language zh. Fixture National live.'


@pytest.fixture
def conn():
    c = sqlite3.connect(':memory:'); c.row_factory = sqlite3.Row
    worker.migrate(c)
    c.execute('CREATE TABLE epg_mapping_approvals(channel_id TEXT PRIMARY KEY,revoked INTEGER)')
    yield c
    c.close()


def checked():
    return {'url': URL, 'httpStatus': 200, 'bodyBytes': 200, 'bodySha256': 'a' * 64,
            'visibleText': TEXT, 'linkedRouteSha256': [ROUTE_HASH], 'bodyReferenceSha256': [ROUTE_HASH],
            'result': 'partial_named_identity_evidence', 'checkedAtUtc': NOW}


def packet():
    target = channel()
    return {'policy': review.POLICY, 'target': {**target, 'categoryPath': PATH, 'routeSha256': [ROUTE_HASH]},
            'pages': [{'url': URL, 'bodySha256': 'a' * 64, 'text': TEXT,
                       'linkedRouteSha256': [ROUTE_HASH], 'checkedAtUtc': NOW}]}


def result(supported=True):
    return {'status': 'completed', 'output': [{'type': 'message', 'content': [
        {'type': 'output_text', 'text': json.dumps({'supported': supported, 'reason': 'Fixture checked facts',
         'fields': {key: {'value': value, 'url': URL, 'quote': TEXT} for key, value in VALUES.items()}})}]}]}


def seed(c, check=None):
    target = channel()
    queue.enqueue(c, target, 'fixture-v1', PATH, NOW)
    claim = queue.claim_one(c, NOW)
    request = search.plan(target, PATH, None, 0)
    review.stage_identity(c, claim, request, {'technicalChecks': [checked() if check is None else check]}, NOW)
    worker.finish(c, claim, request, {'technicalChecks': []}, NOW)
    return c.execute('SELECT * FROM epg_research_evidence_reviews').fetchone()


def test_search_then_persisted_review_then_source_search_without_redoing_identity_search(conn):
    calls = []
    def transport(config, body):
        calls.append(body)
        if body.get('text'):
            return result()
        return response(body, [URL])
    first = run(conn, [channel()], max_channels=1, transport=transport, checker=lambda *_: checked())
    assert first['identityEvidencePacketsStaged'] == 1 and not first['identitiesConfirmedThisRun']
    floor, attempts = rows(conn)['fixture-2']['next_retry'], rows(conn)['fixture-2']['attempts']
    second = run(conn, [channel()], max_channels=1, transport=transport, clock=lambda: NOW + 1)
    assert second['identitiesConfirmedThisRun'] == 1 and second['identityAutomaticallyApproved']
    assert second['processedChannels'][0]['stage'] == 'identity_review'
    assert len(calls) == 2 and 'tools' not in calls[-1]
    assert rows(conn)['fixture-2']['next_retry'] == floor and rows(conn)['fixture-2']['attempts'] == attempts
    third = run(conn, [channel()], max_channels=1, transport=transport, clock=lambda: floor)
    assert third['processedChannels'][0]['stage'] == 'xmltv'
    assert third['sourceValidationHandoffs'] == 1
    assert conn.execute('SELECT count(*) FROM epg_research_source_candidates').fetchone()[0] == 1
    assert not conn.execute('SELECT * FROM epg_mapping_approvals').fetchall()


@pytest.mark.parametrize('mutate,code', [
    (lambda r,p: r['fields']['operator'].update(quote='invented operator'), 'quote_not_in_checked_page'),
    (lambda r,p: r['fields']['feedVariant'].update(value='Fixture Plus One'), 'value_not_in_quote'),
    (lambda r,p: r['fields']['countryCode'].update(value='HK'), 'catalog_country_conflict'),
    (lambda r,p: p['pages'][0].update(linkedRouteSha256=[]), 'exact_route_required'),
    (lambda r,p: p['pages'][0].update(checkedAtUtc=NOW - 86401), 'quote_not_in_checked_page'),
    (lambda r,p: r['fields']['language'].update(url='https://unread.example.org/profile'), 'quote_not_in_checked_page')])
def test_review_rejects_unsupported_claims(mutate, code):
    response = result(); value = json.loads(response['output'][0]['content'][0]['text']); evidence = packet()
    mutate(value, evidence); response['output'][0]['content'][0]['text'] = json.dumps(value)
    with pytest.raises(EpgError, match=code): review.decode_review(response, evidence, NOW)


def test_a_search_answer_or_second_tool_is_not_a_checked_page_review():
    response = result(); response['output'].append({'type': 'web_search_call'})
    with pytest.raises(EpgError, match='unexpected_tool'): review.decode_review(response, packet(), NOW)
    with pytest.raises(EpgError): review.decode_review({'status': 'completed', 'output': []}, packet(), NOW)


def test_missing_route_is_actionable_and_does_not_waste_another_ai_request(conn):
    check = checked(); check['linkedRouteSha256'] = []
    seed(conn, check)
    task = conn.execute('SELECT * FROM epg_research_evidence_reviews').fetchone()
    assert task['state'] == 'needs_route_evidence' and review.pending(conn, NOW + 1) is None
    row = conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone()
    request = search.plan(channel(), PATH, None, 1, review_hint=review.search_hint(conn, row))
    assert 'exact live stream' in request['query']
    assert rows(conn)['fixture-2']['identity_evidence'] is None


def pre_review_cache(c, *, route=True, target=None):
    target = channel() if target is None else target
    queue.enqueue(c, target, 'fixture-v1', PATH, NOW)
    claim = queue.claim_one(c, NOW, channel_id=target['id'])
    request = search.plan(target, PATH, None, 0)
    check = checked()
    if not route:
        check.update(linkedRouteSha256=[], bodyReferenceSha256=[])
    worker.finish(c, claim, request, {'technicalChecks': [check]}, NOW)
    with c:
        c.execute('INSERT OR REPLACE INTO epg_research_http_cache VALUES(?,?,?)',
                  (URL, NOW, json.dumps(check)))
    return check


def test_pre_review_cached_evidence_recovers_one_target_without_search_or_retry_reset(conn):
    pre_review_cache(conn)
    before = rows(conn)
    outcome = review.recover_one_cached_identity(conn, NOW + 1, set())
    assert outcome['recoveredChannels'] == outcome['recoveredPages'] == 1
    assert outcome['reviewReady'] and not outcome['identityApproved']
    assert outcome['networkRequests'] == outcome['aiRequests'] == 0
    assert rows(conn) == before
    task = conn.execute('SELECT * FROM epg_research_evidence_reviews').fetchone()
    assert task['state'] == 'pending'
    assert json.loads(task['packet'])['pages'][0]['checkedAtUtc'] == NOW
    assert review.recover_one_cached_identity(conn, NOW + 2, set())['recoveredChannels'] == 0
    assert conn.execute("SELECT count(*) FROM epg_channel_research_audit WHERE event='identity_checked_cache_recovered'").fetchone()[0] == 1


def test_cached_identity_recovery_preview_is_read_only(conn):
    pre_review_cache(conn)
    before = list(conn.iterdump())
    outcome = review.recover_one_cached_identity(conn, NOW + 1, set(), dry_run=True)
    assert outcome['state'] == 'cached_identity_recovery_eligible' and outcome['eligiblePages'] == 1
    assert outcome['recoveredChannels'] == 0 and list(conn.iterdump()) == before


def test_pre_review_cache_without_route_retains_missing_route_gate(conn):
    pre_review_cache(conn, route=False)
    outcome = review.recover_one_cached_identity(conn, NOW + 1, set())
    assert outcome['recoveredChannels'] == 1 and not outcome['reviewReady']
    assert review.pending(conn, NOW + 2) is None
    row = conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone()
    assert review.search_hint(conn, row)['missingRoute']
    assert row['identity_evidence'] is None
    assert not conn.execute('SELECT * FROM epg_mapping_approvals').fetchall()


@pytest.mark.parametrize('mutation', ['missing', 'expired', 'changed_body', 'different_target',
    'drift', 'protected', 'leased', 'later_manual_observation'])
def test_pre_review_cache_recovery_rejects_stale_unrelated_or_reviewed_evidence(conn, mutation):
    check = pre_review_cache(conn)
    with conn:
        if mutation == 'missing':
            conn.execute('DELETE FROM epg_research_http_cache')
        elif mutation == 'expired':
            conn.execute('UPDATE epg_research_http_cache SET checked_at=?', (NOW - 86401,))
        elif mutation in {'changed_body', 'different_target'}:
            if mutation == 'changed_body':
                check['bodySha256'] = 'b' * 64
            else:
                check['visibleText'] = 'Another Fixture 25 Plus One'
            conn.execute('UPDATE epg_research_http_cache SET result=?', (json.dumps(check),))
        elif mutation == 'leased':
            conn.execute("UPDATE epg_channel_research_jobs SET lease_token='other',lease_until=?", (NOW + 100,))
        elif mutation == 'later_manual_observation':
            queue._audit(conn, rows(conn)['fixture-2'], NOW + 1, 'partial_identity_observation',
                         {'findings': ['Prior source excluded by operator review.']})
    if mutation == 'drift':
        queue.enqueue(conn, channel(name='Fixture 2 +1'), 'fixture-v2', PATH, NOW + 1)
    before = rows(conn)
    outcome = review.recover_one_cached_identity(conn, NOW + 2,
        {'fixture-2'} if mutation == 'protected' else set())
    assert outcome['recoveredChannels'] == 0 and rows(conn) == before
    assert not conn.execute('SELECT * FROM epg_research_evidence_reviews').fetchall()


def test_cached_identity_recovery_is_single_channel_bounded(conn):
    pre_review_cache(conn)
    pre_review_cache(conn, target=channel(identity='fixture-other'))
    outcome = review.recover_one_cached_identity(conn, NOW + 1, set())
    assert outcome['recoveredChannels'] == 1
    assert conn.execute('SELECT count(*) FROM epg_research_evidence_reviews').fetchone()[0] == 1


def test_worker_recovers_prior_identity_checks_while_shared_admission_is_waiting(conn):
    pre_review_cache(conn, route=False)
    before = rows(conn)
    worker.control(conn, NOW, 'search_budget_deferred', NOW + 100)
    outcome = run(conn, [channel()], clock=lambda: NOW + 1,
        transport=lambda *_: pytest.fail('Cache recovery made an AI request'))
    assert outcome['state'] == 'waiting_shared_admission'
    assert outcome['cachedIdentityEvidenceRecovery']['recoveredChannels'] == 1
    assert outcome['identityEvidencePacketsStaged'] == 1 and outcome['aiRequestsAttempted'] == 0
    assert rows(conn) == before


def next_identity_search(c, now):
    claim = queue.claim_one(c, now)
    assert claim
    return claim, search.plan(channel(), PATH, None, claim['attempts'])


def test_identity_pages_accumulate_across_searches_without_repeat_download(conn):
    first = checked()
    first['visibleText'] = 'Fixture 2. Fixture Broadcaster.'
    seed(conn, first)
    later = NOW + 21600
    claim, request = next_identity_search(conn, later)
    second = {**checked(), 'url': URL + '/edition', 'bodySha256': 'b' * 64,
              'checkedAtUtc': later, 'linkedRouteSha256': []}
    assert review.stage_identity(conn, claim, request, {'technicalChecks': [second]}, later)
    task = conn.execute('SELECT * FROM epg_research_evidence_reviews').fetchone()
    evidence = json.loads(task['packet'])
    assert {p['url'] for p in evidence['pages']} == {URL, second['url']}
    answer = result()
    value = json.loads(answer['output'][0]['content'][0]['text'])
    for key, field in value['fields'].items():
        field.update(url=URL if key == 'operator' else second['url'],
                     quote=first['visibleText'] if key == 'operator' else TEXT)
    answer['output'][0]['content'][0]['text'] = json.dumps(value)
    facts, error = review.decode_review(answer, evidence, later)
    assert facts['operator'] == 'Fixture Broadcaster' and error is None
    assert len(facts['evidenceUrls']) == 2
    assert rows(conn)['fixture-2']['identity_evidence'] is None
    assert conn.execute('SELECT count(*) FROM epg_mapping_approvals').fetchone()[0] == 0


@pytest.mark.parametrize('mutation', ['identity_changed', 'expired', 'future_timestamp'])
def test_old_evidence_never_crosses_identity_or_original_fetch_freshness(conn, mutation):
    seed(conn)
    later = NOW + 21600
    if mutation == 'identity_changed':
        changed = channel(name='Fixture Different')
        queue.enqueue(conn, changed, 'fixture-v2', PATH, later)
    else:
        task = conn.execute('SELECT * FROM epg_research_evidence_reviews').fetchone()
        evidence = json.loads(task['packet'])
        evidence['pages'][0]['checkedAtUtc'] = later - 86401 if mutation == 'expired' else later + 1
        with conn:
            conn.execute('UPDATE epg_research_evidence_reviews SET packet=?', (json.dumps(evidence),))
    claim = queue.claim_one(conn, later)
    request = search.plan(channel(), PATH, None, 2)
    new = {**checked(), 'url': URL + '/new', 'checkedAtUtc': later, 'linkedRouteSha256': []}
    assert review.stage_identity(conn, claim, request, {'technicalChecks': [new]}, later) is False
    task = conn.execute('SELECT * FROM epg_research_evidence_reviews').fetchone()
    assert task['state'] == 'needs_route_evidence'
    assert [p['url'] for p in json.loads(task['packet'])['pages']] == [new['url']]


@pytest.mark.parametrize('replacement', ['shell', 'failure'])
def test_current_same_url_invalidates_old_body_without_identity_promotion(conn, replacement):
    seed(conn)
    later = NOW + 21600
    claim, request = next_identity_search(conn, later)
    check = {'url': URL, 'httpStatus': 403, 'result': 'access_requires_review'}
    if replacement == 'shell':
        check = {**checked(), 'visibleText': 'Generic JavaScript shell',
                 'result': 'no_selected_identity_text', 'checkedAtUtc': later}
    assert review.stage_identity(conn, claim, request, {'technicalChecks': [check]}, later) is None
    task = conn.execute('SELECT * FROM epg_research_evidence_reviews').fetchone()
    assert task['state'] == 'needs_identity_evidence'
    assert json.loads(task['packet'])['pages'] == []
    assert review.pending(conn, later) is None
    assert rows(conn)['fixture-2']['identity_evidence'] is None
    audit = conn.execute("SELECT evidence FROM epg_channel_research_audit WHERE event='identity_evidence_invalidated'").fetchone()
    assert json.loads(audit[0])['priorPacket']['pages'][0]['url'] == URL
    other = {**checked(), 'url': URL + '/new', 'checkedAtUtc': later, 'linkedRouteSha256': []}
    assert review.stage_identity(conn, claim, request, {'technicalChecks': [other]}, later) is False
    task = conn.execute('SELECT * FROM epg_research_evidence_reviews').fetchone()
    assert task['state'] == 'needs_route_evidence'
    assert [p['url'] for p in json.loads(task['packet'])['pages']] == [other['url']]


def test_accumulated_packet_stays_bounded_and_retains_exact_route_witness(conn):
    seed(conn)
    later = NOW + 21600
    claim, request = next_identity_search(conn, later)
    for index in range(10):
        check = {**checked(), 'url': URL + '/page/' + str(index),
                 'checkedAtUtc': later, 'linkedRouteSha256': []}
        review.stage_identity(conn, claim, request, {'technicalChecks': [check]}, later)
    task = conn.execute('SELECT * FROM epg_research_evidence_reviews').fetchone()
    pages = json.loads(task['packet'])['pages']
    assert len(pages) == review.MAX_IDENTITY_PAGES and any(p['url'] == URL for p in pages)
    large = [{**checked(), 'url': URL + '/large/' + str(index), 'checkedAtUtc': later,
              'visibleText': 'Fixture 2 ' + 'x' * (65536 - 10), 'linkedRouteSha256': []}
             for index in range(3)]
    review.stage_identity(conn, claim, request, {'technicalChecks': large}, later)
    pages = json.loads(conn.execute('SELECT packet FROM epg_research_evidence_reviews').fetchone()[0])['pages']
    assert sum(len(p['text']) for p in pages) <= review.MAX_IDENTITY_TEXT
    assert pages[0]['linkedRouteSha256'] == [ROUTE_HASH]


def test_accumulation_keeps_original_cache_timestamp_and_review_retry_floor(conn):
    seed(conn)
    later = NOW + 21600
    with conn:
        conn.execute('UPDATE epg_research_evidence_reviews SET next_retry=?', (later + 500,))
    claim, request = next_identity_search(conn, later)
    cached = {**checked(), 'url': URL + '/cache', 'checkedAtUtc': later,
              'originalCheckedAtUtc': NOW, 'linkedRouteSha256': []}
    review.stage_identity(conn, claim, request, {'technicalChecks': [cached]}, later)
    task = conn.execute('SELECT * FROM epg_research_evidence_reviews').fetchone()
    assert task['next_retry'] == later + 500
    assert all(p['checkedAtUtc'] == NOW for p in json.loads(task['packet'])['pages'])


def test_missing_field_review_changes_next_query_and_retains_deadline(conn):
    task = seed(conn)
    claim = review.claim_review(conn, task, NOW + 1, set())
    response = result(False)
    value = json.loads(response['output'][0]['content'][0]['text'])
    value['fields']['feedVariant']['value'] = ''
    response['output'][0]['content'][0]['text'] = json.dumps(value)
    outcome = review.finish_review(conn, claim, task, response, NOW + 1)
    assert outcome['state'] == 'needs_identity_evidence'
    row = conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone()
    hint = review.search_hint(conn, row)
    assert hint['unresolvedFields'] == ['feedVariant']
    request = search.plan(channel(), PATH, None, 1, review_hint=hint)
    assert 'regional delayed feed' in request['query']
    assert row['next_retry'] == NOW + 21600


@pytest.mark.parametrize('mutation', ['route', 'category', 'protected'])
def test_cached_review_cannot_survive_catalogue_drift_or_protected_mapping(conn, mutation):
    seed(conn)
    def reload_targets():
        target = channel()
        if mutation == 'route': target['routes'] = [{'url': ROUTE + '/changed'}]
        if mutation == 'protected':
            with conn: conn.execute('INSERT INTO epg_mapping_approvals VALUES(?,0)', (target['id'],))
        return {'version': 'fixture-v2'}, [target], {target['id']: ['changed'] if mutation == 'category' else PATH}
    outcome = run(conn, [channel()], max_channels=1, transport=lambda *_: result(),
                  clock=lambda: NOW + 1, reload_targets=reload_targets)
    assert outcome['identitiesConfirmedThisRun'] == 0
    assert outcome['processedChannels'][0]['state'] == 'stale_result_rejected'


def test_shared_page_reuse_reextracts_new_target_and_route_without_download(conn):
    first, second = channel(identity='fixture-1', name='Fixture One'), channel()
    body = checked(); body['visibleText'] = 'Fixture One and ' + TEXT
    count = []
    checks = {'candidates': [{'url': URL}]}
    first_request = search.plan(first, PATH, None, 0)
    second_request = search.plan(second, PATH, None, 0)
    worker.checked_candidates(conn, checks, first_request, NOW, lambda *_: count.append(1) or body)
    reused = worker.checked_candidates(conn, checks, second_request, NOW + 1, lambda *_: pytest.fail('Cache refetched'))[0]
    assert len(count) == 1 and reused['cacheReused'] and reused['selectedIdentityRechecked']
    assert reused['linkedRouteSha256'] == [ROUTE_HASH] and 'Fixture 2' in ''.join(reused['selectedNameExcerpts'])


def test_unknown_broadcaster_keeps_open_exact_target_discovery_on_retry():
    first = search.plan(channel(name='具体广播二台'), PATH, None, 0)
    second = search.plan(channel(name='具体广播二台'), PATH, None, 1)
    assert 'filters' not in first['body']['tools'][0]
    assert '具体广播二台' in first['query'] and 'CN' not in first['query']
    assert not second['domains'] and 'filters' not in second['body']['tools'][0]
    assert '具体广播二台' in second['query'] and 'Do not research EPG' in second['body']['instructions']
    assert search.candidate_allowed('https://station.example.org/about', [], 'identity')
    assert not search.candidate_allowed('https://station.example.org/news_story/1', [], 'identity')


def source_candidate(c, url='https://broadcaster.example.org/epg.xml', now=NOW):
    queue.enqueue(c, channel(), 'fixture-v1', PATH, now)
    claim = queue.claim_one(c, now)
    facts = {**VALUES, 'categoryPath': PATH, 'evidenceUrls': [URL]}
    queue.confirm_identity(c, claim, facts, now, explicitly_reviewed=True)
    request = search.plan(channel(), PATH, facts, 0)
    evidence = {'technicalChecks': [{'url': url, 'httpStatus': 200, 'contentType': 'application/xml',
                'result': 'reachable_content_and_rights_unverified'}]}
    review.handoff_sources(c, claim, request, evidence, now)
    worker.finish(c, claim, request, evidence, now)


def fixture_xml(now):
    from datetime import datetime, timezone
    def stamp(t): return datetime.fromtimestamp(t, timezone.utc).strftime('%Y%m%d%H%M%S +0000')
    return (f'<tv><channel id="fixture"><display-name>Fixture 2</display-name></channel>'
        f'<programme channel="fixture" start="{stamp(now-60)}" stop="{stamp(now+600)}"><title>Authored current</title></programme>'
        f'<programme channel="fixture" start="{stamp(now+600)}" stop="{stamp(now+1200)}"><title>Authored next</title></programme></tv>').encode()


def test_handoff_is_really_consumed_by_validator_and_shared_without_a_grant(tmp_path):
    from epg_store import migrate
    c = database(tmp_path); worker.migrate(c); migrate(c)
    source_candidate(c)
    calls = []
    def fetch(source):
        calls.append(source['url']); return fixture_xml(NOW), {'sourceUrl': source['url']}
    result = review.validate_one_source(c, tmp_path, NOW + 61, fetcher=fetch)
    assert result['sourceValidatorRequests'] == 1 and result['quality']['currentAndFutureChannels'] == 1
    assert result['state'] == 'programme_data_permission_required' and result['exactFullNameSourceCandidates']
    assert review.validate_one_source(c, tmp_path, NOW + 121, fetcher=lambda *_: pytest.fail('Premature refetch'))['state'] == 'no_due_channel_source'
    assert len(calls) == 1
    assert c.execute('SELECT count(*) FROM source_identities').fetchone()[0] == 1
    for table in ('epg_programmes', 'epg_data_grants', 'epg_mapping_approvals', 'epg_source_payloads'):
        assert c.execute('SELECT count(*) FROM ' + table).fetchone()[0] == 0
    c.close()


def test_stale_only_xml_is_failed_not_fake_coverage(tmp_path):
    from epg_store import migrate
    c = database(tmp_path); worker.migrate(c); migrate(c); source_candidate(c)
    outcome = review.validate_one_source(c, tmp_path, NOW + 61,
        fetcher=lambda source: (fixture_xml(NOW - 864000), {'sourceUrl': source['url']}))
    assert outcome['state'] == 'source_quality_retry' and outcome['safeError'] == 'empty_or_expired_data'
    assert c.execute('SELECT count(*) FROM epg_programmes').fetchone()[0] == 0
    c.close()


def test_source_timeout_preserves_other_data_and_retry(tmp_path):
    from epg_store import migrate
    c = database(tmp_path); worker.migrate(c); migrate(c); source_candidate(c)
    def fail(*_): raise TimeoutError('never persist private text')
    outcome = review.validate_one_source(c, tmp_path, NOW + 61, fetcher=fail)
    assert outcome['safeError'] == 'network_failure' and outcome['sourceNextRetryAtUtc'] >= NOW + 3661
    assert 'private text' not in json.dumps(outcome)
    assert c.execute('SELECT count(*) FROM epg_data_grants').fetchone()[0] == 0
    c.close()


def test_source_index_matching_is_limited_to_the_current_reviewed_channel(conn):
    import epg_discovery as discovery
    target, other = channel(), channel(identity='unknown')
    queue.enqueue(conn, target, 'v1', PATH, NOW)
    claim = queue.claim_one(conn, NOW)
    queue.confirm_identity(conn, claim, {**VALUES, 'categoryPath': PATH, 'evidenceUrls': [URL]}, NOW,
                           explicitly_reviewed=True)
    assert discovery.reviewed_targets(conn, [target, other]) == {target['id']}
    changed = copy.deepcopy(target); changed['routes'][0]['url'] += '/changed'
    assert discovery.reviewed_targets(conn, [changed, other]) == set()
    with conn: conn.execute('INSERT INTO epg_mapping_approvals VALUES(?,0)', (target['id'],))
    assert discovery.reviewed_targets(conn, [target]) == set()


def test_budget_wait_keeps_pending_review_packet_and_does_not_repeat_search(conn):
    seed(conn)
    task = dict(conn.execute('SELECT * FROM epg_research_evidence_reviews').fetchone())
    before = rows(conn)
    def blocked(*_): raise search.SearchDeferred('search_budget_deferred', NOW + 600)
    outcome = run(conn, [channel()], max_channels=1, clock=lambda: NOW + 1, reserve=blocked,
                  transport=lambda *_: pytest.fail('A full budget reached the model'))
    assert outcome['aiRequestsAttempted'] == 0 and rows(conn) == before
    assert dict(conn.execute('SELECT * FROM epg_research_evidence_reviews').fetchone()) == task


def test_known_provider_restrictions_are_not_retried_or_silently_overridden(tmp_path):
    from epg_store import migrate
    c = database(tmp_path); worker.migrate(c); migrate(c)
    source_candidate(c, 'https://www.rthk.hk/epg.xml')
    outcome = review.validate_one_source(c, tmp_path, NOW + 61,
        fetcher=lambda *_: pytest.fail('Known excluded provider reached the network'))
    assert outcome['state'] == 'retained_rights_exclusion' and outcome['sourceValidatorRequests'] == 0
    assert c.execute('SELECT count(*) FROM source_health').fetchone()[0] == 0
    c.close()


def test_complete_search_proposal_is_checked_and_promoted_without_second_model_request(conn):
    calls = []
    def transport(config, body):
        calls.append(body)
        value = response(body, [URL])
        value['output'].extend(result()['output'])
        return value
    outcome = run(conn, [channel()], max_channels=1, transport=transport, checker=lambda *_: checked())
    assert len(calls) == outcome['aiRequestsAttempted'] == outcome['identitiesConfirmedThisRun'] == 1
    assert outcome['processedChannels'][0]['identityReviewed']
    assert rows(conn)['fixture-2']['next_retry'] == NOW + 3600
    assert review.pending(conn, NOW + 1) is None
    assert json.loads(rows(conn)['fixture-2']['identity_evidence'])['fullName'] == 'Fixture 2'


def test_unquoted_search_proposal_stays_pending_for_checked_evidence(conn):
    def transport(config, body):
        value = response(body, [URL]); proposal = result()
        fields = json.loads(proposal['output'][0]['content'][0]['text'])
        fields['fields']['operator']['quote'] = 'Not actually in the checked document'
        proposal['output'][0]['content'][0]['text'] = json.dumps(fields)
        value['output'].extend(proposal['output']); return value
    outcome = run(conn, [channel()], max_channels=1, transport=transport, checker=lambda *_: checked())
    assert outcome['identitiesConfirmedThisRun'] == 0
    assert rows(conn)['fixture-2']['identity_evidence'] is None and review.pending(conn, NOW + 1)


def test_due_reviewed_channel_advances_before_unconfirmed_peers_in_same_geography(conn):
    from test_epg_auto_search import reviewed
    ready = reviewed(conn, channel(identity='reviewed', name='Fixture Reviewed'))
    unknown = channel(identity='unknown', name='Fixture Unknown')
    queue.enqueue(conn, unknown, 'v1', PATH, NOW)
    with conn:
        conn.execute("UPDATE epg_channel_research_jobs SET priority=1 WHERE channel_id='reviewed'")
        conn.execute("UPDATE epg_channel_research_jobs SET priority=0 WHERE channel_id='unknown'")
    outcome = run(conn, [unknown, ready], max_channels=1)
    assert outcome['processedChannels'][0]['channelId'] == ready['id']
    assert outcome['processedChannels'][0]['stage'] == 'xmltv'
    assert rows(conn)['unknown']['attempts'] == 0


def test_source_query_does_not_include_long_human_audit_qualifications():
    from test_epg_channel_research import facts
    evidence = facts(); evidence['feedVariant'] = 'Hong Kong exact main live; physical latency was not measured'
    evidence['language'] = 'en, official technical document contains qualification notes'
    request = search.plan(channel(), PATH, evidence, 0)
    assert 'Hong Kong exact main live' in request['query'] and 'latency was not measured' not in request['query']
    assert 'qualification notes' not in request['query']


def test_retained_due_broadcast_hint_does_not_delete_camera_case_or_change_its_retry(conn):
    camera = channel(identity='a-camera', name='Fixture mountain scenery')
    radio = channel(identity='z-radio', name='Fixture local service')
    paths = {camera['id']: ['中国', '云南'], radio['id']: ['中国', '广播']}
    for target in (camera, radio):
        queue.enqueue(conn, target, 'fixture', paths[target['id']], NOW)
    before = rows(conn)
    chosen = worker.choose(conn, {'version': 'fixture'}, [camera, radio], paths, set(), NOW, set())
    assert chosen['channel_id'] == radio['id']
    assert rows(conn) == before
    assert all(row['identity_evidence'] is None and row['attempts'] == 0 for row in before.values())


@pytest.mark.parametrize('name', ['云南卫视', '雅安新闻综合', 'Fixture Radio 1'])
def test_broadcast_name_hint_is_shared_by_old_and_new_selection(conn, name):
    camera = channel(identity='a-camera', name='Fixture mountain scenery')
    broadcast = channel(identity='z-broadcast', name=name)
    paths = {target['id']: PATH for target in (camera, broadcast)}
    assert worker.broadcast_rank(broadcast) == 0 and worker.broadcast_rank(camera) == 1
    first = worker.choose(conn, {'version': 'fixture'}, [camera, broadcast], paths, set(), NOW, set())
    assert first['channel_id'] == broadcast['id'] and first['identity_evidence'] is None
    queue.enqueue(conn, camera, 'fixture', PATH, NOW)
    before = rows(conn)
    retained = worker.choose(conn, {'version': 'fixture'}, [camera, broadcast], paths, set(), NOW, set())
    assert retained['channel_id'] == broadcast['id'] and rows(conn) == before


def test_retained_broadcast_hint_cannot_bypass_cooldown_or_protected_mapping(conn):
    camera = channel(identity='a-camera', name='Fixture mountain scenery')
    radio = channel(identity='z-radio', name='Fixture Radio 1')
    paths = {target['id']: PATH for target in (camera, radio)}
    for target in (camera, radio):
        queue.enqueue(conn, target, 'fixture', PATH, NOW)
    with conn:
        conn.execute('UPDATE epg_channel_research_jobs SET next_retry=? WHERE channel_id=?', (NOW + 3600, radio['id']))
    before = rows(conn)
    assert worker.choose(conn, {'version': 'fixture'}, [camera, radio], paths, set(), NOW, set())['channel_id'] == camera['id']
    assert worker.choose(conn, {'version': 'fixture'}, [camera, radio], paths, {camera['id']}, NOW, set()) is None
    assert rows(conn) == before


def test_broadcast_hint_keeps_playable_and_jurisdiction_priorities(conn):
    local = channel(identity='a-local', name='Fixture scenery')
    foreign = channel(identity='z-foreign', name='Fixture Radio', country='GB')
    paths = {target['id']: PATH for target in (local, foreign)}
    for target in (local, foreign):
        queue.enqueue(conn, target, 'fixture', PATH, NOW)
    assert worker.choose(conn, {'version': 'fixture'}, [foreign, local], paths, set(), NOW, set())['channel_id'] == local['id']
    unplayable = channel(identity='radio-offline', name='Fixture Radio')
    playable = channel(identity='camera-online', name='Fixture scenery')
    paths.update({target['id']: PATH for target in (unplayable, playable)})
    for target in (unplayable, playable):
        queue.enqueue(conn, target, 'fixture', PATH, NOW)
    with conn:
        conn.execute("UPDATE epg_channel_research_jobs SET priority=1 WHERE channel_id='radio-offline'")
    assert worker.choose(conn, {'version': 'fixture'}, [unplayable, playable], paths, set(), NOW, set())['channel_id'] == playable['id']
