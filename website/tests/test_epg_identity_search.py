"""Offline authored fixtures. No API keys, programme dates or network calls."""
from contextlib import contextmanager
import io
import json
from pathlib import Path
import sqlite3
import sys
import types
import urllib.error
import urllib.request

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_identity_search as s
import epg_identity_search_worker as w
import epg_channel_research as q
from epg_ingest import EpgError

NOW = 1792288800


def channel():
    return {'id': s.CHANNEL_ID, 'name': s.NAME, 'epgId': s.NAME,
            'countryCode': 'CN', 'regionCode': None,
            'routes': [{'url': 'http://satellitepull.cnr.cn/live/wxgdwtgb/playlist.m3u8'}]}


def settings():
    return {'baseUrl': 'https://ccnode.briconbric.com:49531/v1', 'apiKey': 'fixture-not-a-key',
            'model': 'gpt-6-sol', 'localTls': True}


def response(urls=None):
    return {'status': 'completed', 'output': [{'id': 'fixture-search', 'type': 'web_search_call',
        'status': 'completed', 'action': {'type': 'search', 'query': s.QUERY,
         'sources': [{'url': url, 'title': 'Untrusted editorial title never stored'}
                     for url in (urls or ['https://m.qtfm.cn/channels/471/'])]}}]}


def event(value):
    return ('data: ' + json.dumps(value) + '\n\n').encode()


@pytest.fixture
def conn():
    c = sqlite3.connect(':memory:')
    c.row_factory = sqlite3.Row
    q.migrate(c)
    c.execute('CREATE TABLE epg_checkpoints(name TEXT PRIMARY KEY,value TEXT NOT NULL)')
    c.execute('CREATE TABLE epg_mapping_approvals(channel_id TEXT PRIMARY KEY,revoked INTEGER)')
    q.enqueue(c, channel(), 'fixture-v1', ['中国', '广播'], NOW)
    other = {**channel(), 'id': 'fixture-other'}
    q.enqueue(c, other, 'fixture-v1', ['中国', '广播'], NOW)
    yield c
    c.close()


def row(c):
    return dict(c.execute('SELECT * FROM epg_channel_research_jobs WHERE channel_id=?', (s.CHANNEL_ID,)).fetchone())


def run(c, **kwargs):
    return w.run(c, {'version': 'fixture-v1'}, [channel()], {s.CHANNEL_ID: ['中国', '广播']},
        kwargs.pop('settings_factory', settings), None, clock=kwargs.pop('clock', lambda: NOW),
        transport=kwargs.pop('transport', lambda *_: response()),
        reserve=kwargs.pop('reserve', lambda *_: None), **kwargs)


def test_request_matches_proven_minimal_protocol_and_only_identity():
    body = s.request_body('gpt-6-sol')
    assert body['store'] is False and body['stream'] is True
    assert body['input'] == [{'role': 'user', 'content': s.QUERY}]
    assert not {'max_tool_calls', 'max_output_tokens', 'parallel_tool_calls'} & body.keys()
    assert body['tools'][0]['filters']['allowed_domains'] == s.DOMAINS
    assert 'Do not research EPG' in body['instructions']
    with pytest.raises(EpgError):
        s.request_body('gpt-6-luna')


@pytest.mark.parametrize('field,value', [('name', 'Other station'), ('epgId', None),
    ('countryCode', 'HK'), ('regionCode', 'other'), ('routes', []),
    ('routes', [{'url': 'https://cnr.cn/other.m3u8'}])])
def test_exact_target_guard(field, value):
    target = channel(); target[field] = value
    with pytest.raises(EpgError):
        s.target_payload(target, ['中国', '广播'])


def test_stream_chunk_boundaries_crlf_and_one_completed_search():
    raw = event({'type': 'response.output_item.added', 'item': {'type': 'web_search_call', 'id': 'fixture-search'}})
    raw += event({'type': 'response.web_search_call.searching', 'item_id': 'fixture-search'})
    raw += event({'type': 'response.completed', 'response': response()})
    raw = raw.replace(b'\n', b'\r\n')
    for size in (1, 7, 8192):
        p = s.ResponseStream()
        for offset in range(0, len(raw), size):
            p.feed(raw[offset:offset + size])
        assert s.decode(p.finish(), NOW)['toolCalls'] == 1


def test_second_tool_stops_stream_before_reading_remainder():
    p = s.ResponseStream()
    p.feed(event({'type': 'response.output_item.added', 'item': {'type': 'web_search_call', 'id': 'one'}}))
    with pytest.raises(EpgError, match='tool_call_limit'):
        p.feed(event({'type': 'response.web_search_call.searching', 'item_id': 'two'}))
    assert not p.completed


@pytest.mark.parametrize('raw', [b'', b'data: [DONE]\n\n', b'data: []\n\n',
    b'data: bad-json\n\n', event({'type': 'response.failed'}), b'x' * (s.LIMIT + 1)])
def test_invalid_or_uncompleted_stream_rejected(raw):
    with pytest.raises(EpgError):
        p = s.ResponseStream(); p.feed(raw); p.finish()


def test_duplicate_completions_rejected():
    p = s.ResponseStream()
    p.feed(event({'type': 'response.completed', 'response': response()}))
    with pytest.raises(EpgError):
        p.feed(event({'type': 'response.completed', 'response': response()}))


def test_unverified_technical_urls_only_no_titles_or_model_answers():
    v = s.decode(response(['https://www.gdtv.cn/', 'https://m.qtfm.cn/channels/471/',
        'https://www.gdtv.cn/editorial/story', 'https://m.qtfm.cn/channels/471/from/20231009',
        'https://img.gdtv.cn/attach/202302/historical.pdf', 'https://www.qtfm.cn/?token=secret',
        'https://127.0.0.1/private', 'https://unreviewed.example.org/']), NOW)
    assert len(v['candidates']) == 2 and v['excludedSourceReferences'] == 6
    assert 'editorial' not in json.dumps(v) and 'secret' not in json.dumps(v)
    assert v['identityApproved'] is v['programmeSearchPerformed'] is v['published'] is False
    assert v['newMappings'] == v['newGrants'] == v['newProgrammeRows'] == 0


@pytest.mark.parametrize('mutation', [lambda v: v.update(status='incomplete'),
    lambda v: v.update(output=[{'type': 'message', 'content': 'I searched'}]),
    lambda v: v['output'][0]['action'].update(query='Other station'),
    lambda v: v['output'][0]['action'].update(queries=[]),
    lambda v: v['output'][0]['action'].update(type='open_page'),
    lambda v: v['output'].append(v['output'][0]),
    lambda v: v['output'].append({'type': 'function_call'})])
def test_no_plain_answer_or_wrong_target_or_extra_tool_success(mutation):
    v = response(); mutation(v)
    with pytest.raises(EpgError):
        s.decode(v, NOW)


def test_idle_preserves_all_jobs_attempts_and_retry_no_configuration_or_budget(conn):
    with conn:
        conn.execute('UPDATE epg_channel_research_jobs SET next_retry=? WHERE channel_id=?', (NOW + 3600, s.CHANNEL_ID))
    before = [tuple(r) for r in conn.execute('SELECT * FROM epg_channel_research_jobs ORDER BY channel_id')]
    def forbidden(*_):
        pytest.fail('Idle worker read configuration/reserved budget/made network request')
    result = run(conn, settings_factory=forbidden, reserve=forbidden, transport=forbidden)
    assert result['state'] == 'waiting_recorded_retry' and result['aiRequestsAttempted'] == 0
    assert before == [tuple(r) for r in conn.execute('SELECT * FROM epg_channel_research_jobs ORDER BY channel_id')]


def test_one_due_identity_search_is_durable_idempotent_and_no_other_changes(conn):
    other = tuple(conn.execute("SELECT * FROM epg_channel_research_jobs WHERE channel_id='fixture-other'").fetchone())
    result = run(conn)
    assert result['state'] == 'identity_candidates_require_review' and result['aiRequestsAttempted'] == 1
    after = row(conn)
    assert after['attempts'] == 1 and after['identity_evidence'] is None and after['state'] == 'pending_identity'
    assert after['next_retry'] == NOW + 21600 and after['lease_token'] is None
    assert tuple(conn.execute("SELECT * FROM epg_channel_research_jobs WHERE channel_id='fixture-other'").fetchone()) == other
    assert run(conn)['aiRequestsAttempted'] == 0 and row(conn) == after
    audits = conn.execute("SELECT evidence FROM epg_channel_research_audit WHERE event='bounded_identity_search_finished'").fetchall()
    assert len(audits) == 1 and json.loads(audits[0][0])['identityApproved'] is False


def test_shared_budget_deferral_does_not_claim_or_move_real_floor(conn):
    before = row(conn)
    def deferred(*_):
        raise s.SearchDeferred('search_budget_deferred', NOW + 500)
    result = run(conn, reserve=deferred)
    assert result['state'] == 'waiting_shared_budget' and row(conn) == before
    def forbidden(*_):
        pytest.fail('Persistent admission backoff ignored')
    assert run(conn, reserve=forbidden)['aiRequestsAttempted'] == 0


@pytest.mark.parametrize('code,manual,seconds', [('identity_search_upstream_rate_limit', False, 7200),
    ('identity_search_transport_unavailable', False, 3600),
    ('identity_search_proxy_protocol_unverified', False, 21600),
    ('identity_search_upstream_auth_or_balance', True, 7 * 86400)])
def test_failures_preserve_safe_error_and_durable_backoff(conn, code, manual, seconds):
    def failed(*_):
        raise s.SearchDeferred(code, NOW + seconds, requires_manual_action=manual)
    result = run(conn, transport=failed)
    assert result['safeError'] == code and row(conn)['next_retry'] == NOW + seconds
    assert row(conn)['identity_evidence'] is None and result['requiresManualAction'] is manual
    if manual:
        def forbidden(*_):
            pytest.fail('Manual suspension automatically retried')
        result = run(conn, clock=lambda: NOW + 8 * 86400, transport=forbidden)
        assert result['state'] == 'waiting_manual_action' and result['aiRequestsAttempted'] == 0


def test_timeout_preserves_crash_floor_and_no_success_evidence(conn):
    def timed_out(*_):
        raise TimeoutError('untrusted secret upstream text')
    result = run(conn, transport=timed_out)
    assert result['safeError'] == 'identity_search_transport_unavailable'
    assert 'secret' not in json.dumps(result) and row(conn)['next_retry'] == NOW + 3600


@pytest.mark.parametrize('kind', ['identity', 'protected', 'lease', 'inactive'])
def test_concurrent_change_rejects_result_without_overwriting_target(conn, kind):
    def changed(*_):
        with conn:
            if kind == 'identity':
                conn.execute("UPDATE epg_channel_research_jobs SET identity_hash='changed' WHERE channel_id=?", (s.CHANNEL_ID,))
            elif kind == 'protected':
                conn.execute('INSERT INTO epg_mapping_approvals VALUES(?,0)', (s.CHANNEL_ID,))
            elif kind == 'lease':
                conn.execute("UPDATE epg_channel_research_jobs SET lease_token='newer' WHERE channel_id=?", (s.CHANNEL_ID,))
            else:
                q.deactivate(conn, s.CHANNEL_ID, NOW, 'protected_mapping')
        return response()
    result = run(conn, transport=changed)
    assert result['state'] == 'result_rejected_stale_claim' and not result['auditRecorded']
    assert not conn.execute("SELECT 1 FROM epg_channel_research_audit WHERE event='bounded_identity_search_finished'").fetchone()


@pytest.mark.parametrize('kind', ['protected', 'reviewed', 'changed_payload', 'policy_expired'])
def test_preflight_guards_make_no_request(conn, kind):
    with conn:
        if kind == 'protected':
            conn.execute('INSERT INTO epg_mapping_approvals VALUES(?,0)', (s.CHANNEL_ID,))
        elif kind == 'reviewed':
            conn.execute("UPDATE epg_channel_research_jobs SET identity_evidence='{}' WHERE channel_id=?", (s.CHANNEL_ID,))
        elif kind == 'changed_payload':
            conn.execute("UPDATE epg_channel_research_jobs SET payload='{}' WHERE channel_id=?", (s.CHANNEL_ID,))
    def forbidden(*_):
        pytest.fail('Guard failed')
    result = run(conn, clock=lambda: s.POLICY_EXPIRES if kind == 'policy_expired' else NOW,
                 settings_factory=forbidden, transport=forbidden)
    assert result['aiRequestsAttempted'] == 0 and row(conn)['attempts'] == 0


def test_existing_longer_floor_and_exponential_identity_backoff(conn):
    run(conn)
    result = run(conn, clock=lambda: NOW + 21600)
    assert row(conn)['attempts'] == 2 and result['nextRetryAtUtc'] == NOW + 21600 + 43200


@pytest.mark.parametrize('base', ['http://ccnode.briconbric.com:49531/v1',
    'https://127.0.0.1:49531/v1', 'https://ccnode.briconbric.com:49531/v1?key=secret',
    'https://ccnode.briconbric.com:443/v1', 'https://user:pass@ccnode.briconbric.com:49531/v1',
    'https://ccnode.briconbric.com:49531/other'])
def test_endpoint_is_fixed_reviewed_https_no_credentials_or_redirect_origin(base):
    with pytest.raises(EpgError):
        s.validate_settings({**settings(), 'baseUrl': base})


def test_actual_stream_transport_closes_on_extra_tool(monkeypatch):
    chunks = [event({'type': 'response.output_item.added', 'item': {'type': 'web_search_call', 'id': 'one'}}),
              event({'type': 'response.output_item.added', 'item': {'type': 'web_search_call', 'id': 'two'}}),
              b'never read']
    class FakeResponse:
        status = 200
        headers = {}
        closed = False
        def geturl(self): return settings()['baseUrl'] + '/responses'
        def read1(self, _): return chunks.pop(0) if chunks else b''
        def __enter__(self): return self
        def __exit__(self, *_): self.closed = True
    fake = FakeResponse()
    monkeypatch.setitem(sys.modules, 'server_worker', types.SimpleNamespace(
        LocalTlsHandler=lambda: object(), NoRedirect=lambda: object()))
    monkeypatch.setattr(urllib.request, 'build_opener', lambda *_: types.SimpleNamespace(open=lambda *a, **k: fake))
    with pytest.raises(EpgError, match='tool_call_limit'):
        s.transport(settings(), s.request_body('gpt-6-sol'))
    assert fake.closed and chunks == [b'never read']


@pytest.mark.parametrize('status,error_code,expected,manual', [
    (401, 'invalid_api_key', 'identity_search_upstream_auth_or_balance', True),
    (402, None, 'identity_search_upstream_auth_or_balance', True),
    (403, None, 'identity_search_upstream_auth_or_balance', True),
    (429, 'insufficient_quota', 'identity_search_upstream_auth_or_balance', True),
    (429, None, 'identity_search_upstream_rate_limit', False),
    (400, 'unsupported_parameter', 'identity_search_proxy_protocol_unverified', False),
    (503, None, 'identity_search_proxy_protocol_unverified', False)])
def test_transport_http_failure_safe_classification(monkeypatch, status, error_code, expected, manual):
    monkeypatch.setitem(sys.modules, 'server_worker', types.SimpleNamespace(
        LocalTlsHandler=lambda: object(), NoRedirect=lambda: object()))
    def fail(*a, **k):
        raise urllib.error.HTTPError('https://redacted.invalid/', status, 'untrusted secret',
            {'Retry-After': '120'}, io.BytesIO(json.dumps({'error': {'code': error_code,
             'message': 'untrusted secret'}}).encode()))
    monkeypatch.setattr(urllib.request, 'build_opener', lambda *_: types.SimpleNamespace(open=fail))
    with pytest.raises(s.SearchDeferred) as error:
        s.transport(settings(), s.request_body('gpt-6-sol'))
    assert error.value.code == expected and error.value.requires_manual_action is manual
    assert 'secret' not in str(error.value)


def test_atomic_admission_concurrency_does_not_claim_changed_identity(conn):
    def mutate(*_):
        with conn:
            conn.execute("UPDATE epg_channel_research_jobs SET identity_evidence='{}' WHERE channel_id=?", (s.CHANNEL_ID,))
    result = run(conn, reserve=mutate)
    assert result['state'] == 'claim_changed_before_request'
    assert result['aiRequestsAttempted'] == 0 and row(conn)['attempts'] == 0


def test_expired_claim_and_crash_never_adopt_search_or_retry_immediately(conn):
    times = iter([NOW, NOW + 121, NOW + 121])
    result = run(conn, clock=lambda: next(times))
    assert result['state'] == 'result_rejected_stale_claim' and not result['auditRecorded']
    assert row(conn)['next_retry'] == NOW + 3600
    assert run(conn)['aiRequestsAttempted'] == 0


def test_manual_suspension_is_committed_with_failure_audit(conn):
    claimed = w.claim_target(conn, row(conn), NOW)
    w.finish(conn, claimed, None, NOW + 1, error='identity_search_upstream_auth_or_balance',
             retry_at=NOW + 7 * 86400, manual=True)
    assert conn.execute('SELECT 1 FROM epg_checkpoints WHERE name=?', (w.SUSPENSION,)).fetchone()
    assert run(conn)['state'] == 'waiting_manual_action'


def test_shared_budget_reservation_is_atomic_and_preserves_history():
    c = sqlite3.connect(':memory:')
    c.execute('CREATE TABLE ai_requests(started INTEGER NOT NULL)')
    c.executemany('INSERT INTO ai_requests VALUES(?)', [(NOW - 4000,)] * 499)
    c.commit()
    @contextmanager
    def factory():
        try:
            yield c
            c.commit()
        except BaseException:
            c.rollback()
            raise
    s.reserve_shared_budget(factory, NOW)
    with pytest.raises(s.SearchDeferred, match='search_budget_deferred'):
        s.reserve_shared_budget(factory, NOW)
    assert c.execute('SELECT count(*) FROM ai_requests').fetchone()[0] == 500
    c.close()
