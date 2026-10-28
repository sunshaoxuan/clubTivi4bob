"""Mock-only protected search protocol tests; no credentials or network."""
from contextlib import contextmanager
import copy
import io
import json
from pathlib import Path
import sqlite3
import sys
import urllib.error
import pytest
sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_channel_research as q
import epg_channel_search as search
from epg_ingest import EpgError

NOW = 1792209600
DOMAINS = ['broadcaster.example.org', 'data.example.org']
FACTS = {'fullName':'Fixture Taichung Radio', 'operator':'Fixture Broadcaster', 'countryCode':'TW',
         'channelNumber':'94.5 / TCS', 'language':'zh', 'feedVariant':'regional-online-live',
         'categoryPath':['Fixture radio'], 'evidenceUrls':['https://broadcaster.example.org/live/']}
SETTINGS = {'baseUrl':'https://proxy.example.org/v1', 'apiKey':'fixture-not-a-real-key',
            'model':'gpt-6-luna', 'localTls':True, 'enforceLocalBudget':False}


@pytest.fixture
def budget():
    conn = sqlite3.connect(':memory:')
    conn.execute('CREATE TABLE ai_requests(started INTEGER NOT NULL)');conn.commit()
    @contextmanager
    def factory():
        try:
            yield conn
            conn.commit()
        except BaseException:
            conn.rollback()
            raise
    yield conn, factory
    conn.close()


def response(sources=None, queries=None):
    return {'status':'completed', 'output':[{'type':'web_search_call', 'status':'completed',
        'action':{'type':'search', 'queries':queries if queries is not None else [FACTS['fullName']+' EPG XMLTV'],
                  'sources':sources if sources is not None else [
                      {'url':'https://broadcaster.example.org/schedule/', 'title':'Fixture schedule'}]}}]}


def decode(value):
    return search.decode_search_response(value, FACTS, DOMAINS, ['Fixture requested query'], NOW)


def test_request_preserves_model_has_explicit_tool_bounds_and_no_private_context():
    body, terms = search.prepare_search_request(FACTS, 'gpt-6-luna', DOMAINS)
    assert body['model'] == 'gpt-6-luna' and body['store'] is False
    assert body['max_tool_calls'] == 3 and body['parallel_tool_calls'] is False
    assert body['tool_choice'] == 'required' and len(terms) == 4
    assert all(FACTS['fullName'] in term for term in terms)
    assert body['tools'][0]['filters']['allowed_domains'] == sorted(DOMAINS)
    assert body['include'] == ['web_search_call.action.sources']
    assert 'apiKey' not in json.dumps(body) and 'favourites' not in json.dumps(body)
    assert FACTS['evidenceUrls'][0] not in json.dumps(body)


@pytest.mark.parametrize('mutation', [lambda f:f.pop('operator'),lambda f:f.update(language=''),
    lambda f:f.update(evidenceUrls=['https://127.0.0.1/private']),lambda f:f.update(categoryPath=[])])
def test_no_incomplete_identity_or_private_evidence(mutation):
    facts = copy.deepcopy(FACTS);mutation(facts)
    with pytest.raises((EpgError, ValueError)):
        search.prepare_search_request(facts, 'gpt-6-luna', DOMAINS)


@pytest.mark.parametrize('domains', [[], ['*'], ['localhost'], ['127.0.0.1'],
    ['example.org/?key=fixture'], ['https://example.org'], ['data.internal']])
def test_only_explicit_reviewed_public_domains(domains):
    with pytest.raises((EpgError, ValueError)):
        search.prepare_search_request(FACTS, 'gpt-6-luna', domains)


def test_shared_budget_reservation_is_single_and_preserves_old_history(budget):
    conn, factory = budget
    with conn:conn.execute('INSERT INTO ai_requests VALUES(?)', (NOW-90000,))
    search.reserve_shared_budget(factory, NOW)
    assert [r[0] for r in conn.execute('SELECT started FROM ai_requests ORDER BY started')] == [NOW-90000, NOW]


@pytest.mark.parametrize('count,age,expected', [(60,100,3501),(500,7200,79201)])
def test_shared_limits_apply_even_if_classification_settings_opt_out(budget,count,age,expected):
    conn, factory = budget
    with conn:conn.executemany('INSERT INTO ai_requests VALUES(?)', [(NOW-age,)]*count)
    with pytest.raises(search.SearchDeferred) as caught:
        search.protected_transport(SETTINGS, {}, factory, NOW, fetch=lambda *_a,**_k:pytest.fail('no API call'))
    assert caught.value.code == 'search_budget_deferred' and caught.value.retry_at == NOW+expected
    assert conn.execute('SELECT count(*) FROM ai_requests').fetchone()[0] == count


def test_transport_uses_existing_https_endpoint_and_raw_bytes_contract(budget):
    conn, factory = budget;seen=[]
    def fetch(url, body, headers, **kwargs):
        seen.append((url, body, headers, kwargs));return json.dumps(response()).encode()
    body, _ = search.prepare_search_request(FACTS, 'gpt-6-luna', DOMAINS)
    result = search.protected_transport(SETTINGS, body, factory, NOW, fetch=fetch)
    assert result == response() and len(seen) == 1
    assert seen[0][0] == 'https://proxy.example.org/v1/responses'
    assert seen[0][3] == {'limit':262144, 'local_tls':True}
    assert conn.execute('SELECT count(*) FROM ai_requests').fetchone()[0] == 1
    assert SETTINGS['apiKey'] not in json.dumps(result)


@pytest.mark.parametrize('base', ['http://proxy.example.org/v1','https://user:fixture@proxy.example.org/v1',
    'https://proxy.example.org/v1?key=fixture','https://proxy.example.org/v1#fragment'])
def test_invalid_endpoint_is_rejected_before_budget_reservation(budget,base):
    conn, factory = budget
    with pytest.raises(EpgError,match='search_unsafe_api_endpoint'):
        search.protected_transport({**SETTINGS,'baseUrl':base}, {}, factory, NOW)
    assert conn.execute('SELECT count(*) FROM ai_requests').fetchone()[0] == 0


@pytest.mark.parametrize('status,error,expected,manual', [(401,None,'search_upstream_auth_or_balance',True),
    (429,'insufficient_quota','search_upstream_auth_or_balance',True),
    (429,None,'search_upstream_rate_limit',False),(404,None,'search_proxy_protocol_unverified',False),
    (400,None,'search_proxy_protocol_unverified',False),
    (405,None,'search_proxy_protocol_unverified',False),
    (422,None,'search_proxy_protocol_unverified',False),
    (503,None,'search_upstream_http',False)])
def test_safe_errors_never_echo_credentials_or_upstream_text(budget,status,error,expected,manual):
    _, factory = budget
    def fetch(*_a,**_k):
        raise urllib.error.HTTPError('https://proxy.example.org/responses',status,'fixture secret text',
             {'Retry-After':'120'}, io.BytesIO(json.dumps({'error':{'code':error,'message':'fixture secret text'}}).encode()))
    with pytest.raises(search.SearchDeferred) as caught:
        search.protected_transport(SETTINGS, {}, factory, NOW, fetch=fetch)
    assert str(caught.value) == expected and caught.value.requires_manual_action is manual
    assert SETTINGS['apiKey'] not in str(caught.value) and 'secret text' not in str(caught.value)
    if status == 429 and error is None:assert caught.value.retry_at == NOW+120
    if status in (400,404,405,422):assert caught.value.retry_at == NOW+21600


def test_text_without_actual_search_is_rejected():
    with pytest.raises(EpgError,match='search_execution_evidence_required'):
        decode({'status':'completed','output':[{'type':'message','content':[{'text':'I searched'}]}]})


def test_search_results_are_only_unverified_metadata_not_coverage():
    value = decode(response())
    assert value['toolCalls'] == 1 and value['actualQueriesDisclosedByProxy']
    assert value['candidates'][0]['state'] == 'unverified_search_candidate'
    assert value['identityApproved'] is value['sourceFreshnessAndRightsVerified'] is value['published'] is False
    assert value['newMappings'] == value['newGrants'] == value['newProgrammeRows'] == 0


def test_queryless_search_calls_are_disclosed_as_missing_query_evidence():
    value = response();value['output'][0]['action'].pop('queries')
    assert decode(value)['actualQueriesDisclosedByProxy'] is False


@pytest.mark.parametrize('url', ['http://broadcaster.example.org/a','https://broadcaster.example.org/a?key=fixture',
    'https://127.0.0.1/a','https://broadcaster.example.org.evil.test/a','https://unreviewed.example.org/a'])
def test_unsafe_or_unreviewed_search_links_are_not_followed_or_retained(url):
    value = decode(response(sources=[{'url':url}]))
    assert not value['candidates'] and len(value['excludedSourceReferences']) == 1
    assert url not in json.dumps(value)


def test_country_only_or_other_station_query_cannot_count_as_channel_search():
    with pytest.raises(EpgError,match='search_query_target_mismatch'):
        decode(response(queries=['TVmaze TW schedules']))


@pytest.mark.parametrize('mutation', [lambda v:v.update(status='in_progress'),
    lambda v:v['output'][0].update(status='failed'),lambda v:v.update(output=v['output']*4)])
def test_incomplete_failed_or_excess_tool_calls_are_rejected(mutation):
    value = response();mutation(value)
    with pytest.raises(EpgError):decode(value)


def test_review_gate_and_proxy_verification_precede_any_transport():
    conn = sqlite3.connect(':memory:');conn.row_factory=sqlite3.Row;q.migrate(conn)
    target = {'id':'fixture-tcs','name':FACTS['fullName'],'countryCode':'TW','regionCode':None,'epgId':None,
              'routes':[{'url':'https://broadcaster.example.org/live/tcs.m3u8'}]}
    q.enqueue(conn,target,'fixture-v1',FACTS['categoryPath'],NOW);claim=q.claim_one(conn,NOW)
    def forbidden(*_a,**_k):pytest.fail('transport must not run')
    with pytest.raises(EpgError,match='search_reviewed_identity_required'):
        search.search_reviewed_channel(conn,claim,SETTINGS,DOMAINS,None,NOW,transport=forbidden)
    q.confirm_identity(conn,claim,FACTS,NOW,explicitly_reviewed=True)
    with pytest.raises(EpgError,match='search_proxy_capability_unverified'):
        search.search_reviewed_channel(conn,claim,SETTINGS,DOMAINS,None,NOW,transport=forbidden)
    before = dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone())
    value = search.search_reviewed_channel(conn,claim,SETTINGS,DOMAINS,None,NOW,
        proxy_capability_verified=True,transport=lambda *_a,**_k:response())
    assert value['candidates'] and before == dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone())
    with pytest.raises(EpgError,match='stale_research_claim'):
        search.search_reviewed_channel(conn,claim,SETTINGS,DOMAINS,None,NOW+121,
            proxy_capability_verified=True,transport=forbidden)
    conn.close()


@pytest.mark.parametrize('raw', [b'not-json', b'x'*262145])
def test_transport_rejects_malformed_and_excess_responses(budget, raw):
    _, factory = budget
    with pytest.raises(EpgError):
        search.protected_transport(SETTINGS, {}, factory, NOW, fetch=lambda *_a,**_k:raw)


def test_source_limit_and_wrong_station_are_not_success():
    with pytest.raises(EpgError,match='search_source_limit'):
        decode(response(sources=[{'url':'https://broadcaster.example.org/a'}]*101))
    with pytest.raises(EpgError,match='search_evidence_limit'):
        decode(response(sources=[{'url':'https://broadcaster.example.org/'+str(i)} for i in range(21)]))
