"""Offline directory fixtures do not approve real station identities or EPG."""
import hashlib
import io
import json
from pathlib import Path
import sqlite3
import sys
from urllib.parse import parse_qs, urlsplit

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_auto_search_worker as worker
import epg_channel_research as queue
import epg_route_directory as directory
import epg_auto_search as search
from epg_ingest import EpgError
from test_epg_channel_research import channel, NOW

PATH = ['Fixture country', '广播']


@pytest.fixture
def conn():
    conn = sqlite3.connect(':memory:')
    conn.row_factory = sqlite3.Row
    worker.migrate(conn)
    directory.migrate(conn)
    conn.execute('CREATE TABLE epg_mapping_approvals(channel_id TEXT PRIMARY KEY,revoked INTEGER)')
    yield conn
    conn.close()


def seed(conn, target=None):
    target = target or channel()
    queue.enqueue(conn, target, 'fixture-v1', PATH, NOW)
    row = dict(conn.execute('SELECT * FROM epg_channel_research_jobs WHERE channel_id=?', (target['id'],)).fetchone())
    return target, row


def result(country='CN'):
    return {'state': 'exact_route_metadata', 'bodyBytes': 123, 'bodySha256': 'a' * 64,
        'records': [{'name': 'Fixture station', 'countrycode': country}]}


def test_exact_directory_observation_does_not_approve_or_modify_job(conn):
    target, row = seed(conn)
    value = directory.check_selected(conn, row, target, PATH, NOW, fetcher=lambda route: result('RU'))
    assert value['catalogueCountryConflict'] is True and value['identityApproved'] is False
    assert value['networkRequests'] == 1 and value['aiRequests'] == value['newMappings'] == value['newGrants'] == 0
    assert dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone()) == row
    audit = json.loads(conn.execute("SELECT evidence FROM epg_channel_research_audit WHERE event='exact_route_directory_observation'").fetchone()[0])
    assert audit['sourceUrl'] == directory.ENDPOINT and not audit['published']
    assert not audit['programmeSearchPerformed']
    assert directory.check_selected(conn, row, target, PATH, NOW + 1,
        fetcher=lambda route: pytest.fail('duplicate download'))['state'] == 'cached_or_backoff'


@pytest.mark.parametrize('change', [
    {'next_retry': NOW + 1}, {'lease_until': NOW + 1}, {'active': 0},
    {'identity_evidence': '{}'}, {'state': 'search_pending'}])
def test_retry_lease_review_and_inactive_guards_prevent_network(conn, change):
    target, row = seed(conn)
    key, value = next(iter(change.items()))
    with conn:
        conn.execute(f'UPDATE epg_channel_research_jobs SET {key}=?', (value,))
    assert directory.check_selected(conn, row, target, PATH, NOW,
        fetcher=lambda route: pytest.fail('protected or future task'))['networkRequests'] == 0


def test_manual_mapping_prevents_network_and_inflight_evidence(conn):
    target, row = seed(conn)
    def fetching(route):
        with conn:
            conn.execute('INSERT INTO epg_mapping_approvals VALUES(?,0)', (target['id'],))
        return result()
    assert directory.check_selected(conn, row, target, PATH, NOW, fetcher=fetching)['state'] == 'stale_target_rejected'
    assert conn.execute('SELECT count(*) FROM epg_route_directory_cache').fetchone()[0] == 0
    assert directory.check_selected(conn, row, target, PATH, NOW,
        fetcher=lambda route: pytest.fail('manual mapping'))['networkRequests'] == 0


def test_shared_route_reuses_metadata_but_audits_each_exact_target_once(conn):
    target, row = seed(conn)
    directory.check_selected(conn, row, target, PATH, NOW, fetcher=lambda route: result('RU'))
    second, second_row = seed(conn, channel(identity='fixture-other', country='RU'))
    for checked_at in (NOW + 1, NOW + 2):
        value = directory.check_selected(conn, second_row, second, PATH, checked_at,
            fetcher=lambda route: pytest.fail('shared metadata downloaded twice'))
        assert value['networkRequests'] == 0
    audits = conn.execute("SELECT evidence FROM epg_channel_research_audit WHERE channel_id=? AND event='exact_route_directory_observation'", (second['id'],)).fetchall()
    assert len(audits) == 1
    evidence = json.loads(audits[0][0])
    assert evidence['checkedAtUtc'] == NOW and evidence['cacheReused']
    assert not evidence['catalogueCountryConflict']


def test_catalogue_drift_rejects_inflight_result_without_history_reset(conn):
    target, row = seed(conn)
    assert directory.check_selected(conn, row, target, PATH, NOW, fetcher=lambda route: result(),
        reload_selected=lambda: 'b' * 64)['state'] == 'stale_target_rejected'
    assert conn.execute('SELECT count(*) FROM epg_route_directory_cache').fetchone()[0] == 0
    assert conn.execute('SELECT count(*) FROM epg_channel_research_audit').fetchone()[0] == 1


@pytest.mark.parametrize('route', ['http://localhost/a', 'http://127.0.0.1/a', 'https://10.0.0.1/a',
    'https://user:pass@example.org/a', 'https://example.org/a?token=private',
    'https://example.org:443/a', 'https://example.org/a#token', 'https://example.internal/a',
    'https://example.org/a\nsecret'])
def test_private_signed_or_ambiguous_routes_are_never_sent(conn, route):
    target = channel()
    target['routes'][0]['url'] = route
    target, row = seed(conn, target)
    assert directory.check_selected(conn, row, target, PATH, NOW,
        fetcher=lambda route: pytest.fail('unsafe URL'))['networkRequests'] == 0


def test_failure_has_safe_error_and_exponential_backoff_without_changing_search_floor(conn):
    target, row = seed(conn)
    def fail(route):
        raise TimeoutError('secret upstream diagnostic')
    value = directory.check_selected(conn, row, target, PATH, NOW, fetcher=fail)
    assert value['nextRetryAtUtc'] == NOW + 3600
    value = directory.check_selected(conn, row, target, PATH, NOW + 3600, fetcher=fail)
    assert value['nextRetryAtUtc'] == NOW + 3600 + 7200
    assert 'secret' not in conn.execute('SELECT result FROM epg_route_directory_cache').fetchone()[0]
    assert dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone()) == row


def test_provider_failure_is_not_retried_for_another_route_until_shared_backoff_expires(conn):
    target, row = seed(conn)
    def fail(route):
        raise TimeoutError('private')
    directory.check_selected(conn, row, target, PATH, NOW, fetcher=fail)
    second = channel(identity='fixture-other')
    second['routes'][0]['url'] = 'https://stream.example.org/another.m3u8'
    second, second_row = seed(conn, second)
    value = directory.check_selected(conn, second_row, second, PATH, NOW + 1,
        fetcher=lambda route: pytest.fail('same failed provider bypassed'))
    assert value['state'] == 'directory_provider_backoff' and value['networkRequests'] == 0
    value = directory.check_selected(conn, second_row, second, PATH, NOW + 3600,
        fetcher=lambda route: result())
    assert value['networkRequests'] == 1
    control = json.loads(conn.execute("SELECT value FROM epg_checkpoints WHERE name='route_directory_control'").fetchone()[0])
    assert control['failures'] == 0 and control['nextRetryAtUtc'] == 0


class Response(io.BytesIO):
    code = 200
    def __init__(self, body, url, **headers):
        super().__init__(body)
        self.url = url
        self.headers = {'Content-Type': 'application/json', **headers}
    def geturl(self):
        return self.url
    def read1(self, size=-1):
        return self.read(size)


class Opener:
    def __init__(self, response):
        self.response = response
        self.requests = []
    def open(self, request, timeout):
        self.requests.append((request, timeout))
        return self.response


def test_network_uses_only_fixed_exact_url_metadata_and_does_not_follow_homepage():
    route = channel()['routes'][0]['url']
    body = json.dumps([{'url': route, 'name': 'Fixture', 'countrycode': 'CN',
        'homepage': 'https://private.invalid/no-follow'},
        {'url': 'https://other.example.org/a', 'url_resolved': route, 'name': 'Wrong edition'}]).encode()
    opener = Opener(Response(body, directory.request_url(route)))
    value = directory.fetch_selected(route, opener=opener)
    assert len(opener.requests) == 1 and len(value['records']) == 1
    request, timeout = opener.requests[0]
    assert timeout == 6 and urlsplit(request.full_url).netloc == 'de1.api.radio-browser.info'
    assert parse_qs(urlsplit(request.full_url).query) == {'url': [route]}
    assert value['bodySha256'] == hashlib.sha256(body).hexdigest()
    assert 'homepage' not in value['records'][0]


@pytest.mark.parametrize('body,headers,url_override', [
    (b'{}', {}, None), (b'not-json', {}, None), (b'[]', {'Content-Encoding': 'gzip'}, None),
    (b'[]', {'Content-Type': 'audio/mpeg'}, None), (b'[]', {}, 'https://other.example.org/'),
    (b'[]', {'Content-Length': '65537'}, None), (b' ' * 65537, {}, None),
    (json.dumps([{}] * 21).encode(), {}, None),
])
def test_response_redirect_type_compression_shape_and_size_rejected(body, headers, url_override):
    route = channel()['routes'][0]['url']
    opener = Opener(Response(body, url_override or directory.request_url(route), **headers))
    with pytest.raises(ValueError):
        directory.fetch_selected(route, opener=opener)


def test_directory_can_run_during_ai_admission_wait_without_spending_ai_or_advancing_job(conn):
    target, before = seed(conn)
    worker.control(conn, NOW, 'search_budget_deferred', NOW + 3600)
    value = worker.run(conn, {'version': 'fixture-v1'}, [target], {target['id']: PATH},
        lambda: pytest.fail('AI config during pause'), None, clock=lambda: NOW, monotonic=lambda: 0,
        route_directory_checker=lambda conn, row, channel, path, now:
            directory.check_selected(conn, row, channel, path, now, fetcher=lambda route: result()))
    assert value['state'] == 'waiting_shared_admission'
    assert value['aiRequestsAttempted'] == 0 and value['routeDirectoryIdentity']['networkRequests'] == 1
    assert dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone()) == before


def test_manual_action_pause_is_not_bypassed(conn):
    target, before = seed(conn)
    worker.control(conn, NOW, 'upstream_authentication_failed', NOW + 3600, manual=True)
    value = worker.run(conn, {'version': 'fixture-v1'}, [target], {target['id']: PATH},
        lambda: pytest.fail('AI config during pause'), None, clock=lambda: NOW, monotonic=lambda: 0,
        route_directory_checker=lambda *args: pytest.fail('manual-action pause'))
    assert value['state'] == 'waiting_manual_action' and 'routeDirectoryIdentity' not in value
    assert dict(conn.execute('SELECT * FROM epg_channel_research_jobs').fetchone()) == before


def test_directory_rotates_checked_targets_while_ai_still_waits_and_preserves_model_floors(conn):
    first, before = seed(conn)
    second = channel(identity='fixture-second')
    second['routes'][0]['url'] = 'https://stream.example.org/second.m3u8'
    worker.control(conn, NOW, 'search_budget_deferred', NOW + 3600)
    channels = [first, second]
    observed = []
    def check(conn, row, channel, path, now):
        observed.append(channel['id'])
        return directory.check_selected(conn, row, channel, path, now, fetcher=lambda route: result())
    for _ in range(2):
        worker.run(conn, {'version': 'fixture-v1'}, channels, {c['id']: PATH for c in channels},
            lambda: pytest.fail('AI admission still waiting'), None, clock=lambda: NOW, monotonic=lambda: 0,
            route_directory_checker=check, route_directory_due=directory.recent_target_ids)
    assert len(observed) == 2 and len(set(observed)) == 2
    assert dict(conn.execute('SELECT * FROM epg_channel_research_jobs WHERE channel_id=?', (first['id'],)).fetchone()) == before
    assert directory.recent_target_ids(conn, NOW + directory.TTL) == set()


def test_guangxi_traffic_researched_alias_is_bound_to_complete_catalogue_and_route():
    target = {'id': 'channel-1b36922d5516d615abcc3a7e', 'name': '广西交通广播',
        'countryCode': 'CN', 'regionCode': None, 'epgId': None,
        'routes': [{'url': 'http://satellitepull.cnr.cn/live/wx32gxjtgb/playlist.m3u8'}]}
    assert search.research_profile(target) == ('广西交通台', ['qtfm.cn'])
    for key, changed in [('name', 'Another station'), ('countryCode', 'TW'),
                         ('regionCode', 'another edition'), ('epgId', 'another-epg')]:
        assert search.research_profile({**target, key: changed}) == ('', [])
    assert search.research_profile({**target, 'routes': [{'url': 'https://other.example.org/feed'}]}) == ('', [])
