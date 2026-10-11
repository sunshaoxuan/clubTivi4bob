import hashlib
import sys
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).parents[1]))
import catalog_inventory
import network_routes as network
from catalog_inventory import database, ingest, ingest_events
from process_channel_inventory import process

URL = 'https://media.example.org/news.m3u8'
OTHER = 'https://media.example.org/other.m3u8'
CN = {'countryCode': 'CN', 'regionCode': 'GD', 'asn': 4134}
US = {'countryCode': 'US', 'regionCode': 'CA', 'asn': 7922}


def seed(path):
    ingest([{'name': 'News', 'url': url, 'group': '国际 / 美国', 'source': 'test', 'blocked': False}
            for url in (URL, OTHER)], 'a' * 64, path)
    process(path, verifier=lambda _: True)


def observation(path, profile, reporter, index, url=URL, **values):
    return ingest_events([{'id': f'{index:032x}', 'kind': 'health', 'url': url,
                          'networkToken': network.issue_profile(profile, path)['token'],
                          'observation': 'playback', **values}], reporter, path)


def ranks(path, profile):
    with database(path) as conn:
        return {item['url']: item for item in network.rank_routes(conn, [URL, OTHER], profile)}


def test_country_failures_cannot_affect_foreign_viewers(tmp_path):
    seed(tmp_path)
    for i in range(3):
        assert observation(tmp_path, CN, str(i) * 64, i, failure=10)['receipts'][0]['status'] == 'applied'
        observation(tmp_path, US, str(i + 3) * 64, i + 10, success=10)
    assert ranks(tmp_path, CN)[URL]['score'] < .5
    assert ranks(tmp_path, US)[URL]['score'] > .5
    assert ranks(tmp_path, {'countryCode': 'JP'})[URL]['score'] == .5
    with database(tmp_path) as conn:
        assert tuple(conn.execute('SELECT success_votes,failure_votes FROM routes WHERE url=?', (URL,)).fetchone()) == (0, 0)


def test_relay_observations_are_isolated_from_direct_transport(tmp_path):
    seed(tmp_path)
    observation(tmp_path, CN, 'b' * 64, 1, failure=10)
    token = network.issue_profile(CN, tmp_path)['token']
    ingest_events([{'id': 'e' * 32, 'kind': 'health', 'url': URL,
        'networkToken': token, 'observation': 'playback', 'success': 10,
        'transport': 'server-relay'}], 'b' * 64, tmp_path)
    with database(tmp_path) as conn:
        assert network.rank_routes(conn, [URL], CN)[0]['score'] < .5
        assert network.rank_routes(conn, [URL], CN, transport='server-relay')[0]['score'] > .5


def test_same_country_prefers_exact_operator_and_region(tmp_path):
    seed(tmp_path)
    observation(tmp_path, CN, 'b' * 64, 1, failure=10)
    unicom = {**CN, 'asn': 4837}
    observation(tmp_path, unicom, 'c' * 64, 2, success=10)
    assert ranks(tmp_path, CN)[URL]['score'] < .5
    assert ranks(tmp_path, unicom)[URL]['score'] > .5
    assert ranks(tmp_path, CN)[URL]['scope'] == 'region-asn'


def test_receipts_deduplicate_and_daily_influence_is_bounded(tmp_path):
    seed(tmp_path)
    result = observation(tmp_path, CN, 'b' * 64, 1, success=10)
    assert observation(tmp_path, CN, 'b' * 64, 1, success=10) == result
    for i in range(2, 12): observation(tmp_path, CN, 'b' * 64, i, success=10)
    with database(tmp_path) as conn:
        assert conn.execute('SELECT sum(successes) FROM route_network_health').fetchone()[0] == 20


def test_unknown_legacy_failures_do_not_leak_into_country(tmp_path):
    seed(tmp_path)
    ingest_events([{'id': 'c' * 32, 'kind': 'health', 'url': URL, 'failure': 10}], 'b' * 64, tmp_path)
    assert ranks(tmp_path, CN)[URL]['score'] == .5
    assert ranks(tmp_path, {})[URL]['score'] == .5


def test_byte_probe_has_less_weight_than_decoded_playback(tmp_path):
    seed(tmp_path)
    token = network.issue_profile(CN, tmp_path)['token']
    ingest_events([{'id': 'd' * 32, 'kind': 'health', 'url': URL, 'success': 2,
                   'networkToken': token, 'observation': 'probe',
                   'firstByteMs': 300, 'bytesPerSecond': 900000}], 'b' * 64, tmp_path)
    observation(tmp_path, CN, 'b' * 64, 2, url=OTHER, success=2)
    assert ranks(tmp_path, CN)[URL]['samples'] < ranks(tmp_path, CN)[OTHER]['samples']
    assert ranks(tmp_path, CN)[URL]['decodedPlayback'] == 0
    assert ranks(tmp_path, CN)[OTHER]['decodedPlayback'] == 1


def test_manual_skip_lowers_regional_score_and_retirement_is_global(tmp_path):
    seed(tmp_path)
    observation(tmp_path, CN, 'b' * 64, 1, success=2)
    before = ranks(tmp_path, CN)[URL]['score']
    token = network.issue_profile(CN, tmp_path)['token']
    ingest_events([{'id': 'e' * 32, 'kind': 'health', 'url': URL, 'failure': 1,
                   'networkToken': token, 'observation': 'manual'}], 'b' * 64, tmp_path)
    assert ranks(tmp_path, CN)[URL]['score'] < before
    ingest_events([{'id': 'f' * 32, 'kind': 'retire', 'url': URL}], 'b' * 64, tmp_path)
    assert URL not in ranks(tmp_path, CN)
    assert URL not in ranks(tmp_path, US)


def test_one_server_cannot_remove_previously_reviewed_routes(tmp_path):
    seed(tmp_path)
    with database(tmp_path) as conn:
        conn.execute('UPDATE routes SET failures=50,success_at=?', (int(time.time()) - 60 * 86400,))
    process(tmp_path, limit=0)
    from test_shared_catalog_events import snapshot
    assert sum(len(c['routes']) for c in snapshot(tmp_path)['channels']) == 2


def test_tampered_and_expired_tokens_rejected(tmp_path):
    token = network.issue_profile(CN, tmp_path, now=1000)['token']
    assert network.verify_token(token, tmp_path, now=2000)['countryCode'] == 'CN'
    with pytest.raises(ValueError): network.verify_token(token + '0', tmp_path, now=2000)
    with pytest.raises(ValueError): network.verify_token(token, tmp_path, now=1000 + network.TOKEN_SECONDS + 1)
    assert (tmp_path / 'network-profile.key').stat().st_mode & 0o777 == 0o600


def test_profile_and_ranking_http_ignore_spoofed_headers(tmp_path, monkeypatch):
    seed(tmp_path)
    monkeypatch.setattr(catalog_inventory, 'DATA', tmp_path)
    monkeypatch.setattr(network, 'resolve_address', lambda address, _: network.normalize_profile(CN if address == '1.1.1.1' else {}))
    app = FastAPI()
    app.include_router(network.router)
    client = TestClient(app, client=('1.1.1.1', 50000))
    profile = client.get('/api/v1/channel-catalog/network-profile', headers={'cf-ipcountry': 'US', 'X-Forwarded-For': '8.8.8.8'}).json()
    assert profile['countryCode'] == 'CN'
    assert 'ip' not in profile
    assert network.verify_token(profile['token'], tmp_path)['asn'] == CN['asn']
    response = client.post('/api/v1/channel-catalog/rank', json={'schemaVersion': 1, 'urls': [URL, OTHER]})
    assert response.status_code == 200
    assert len(response.json()['routes']) == 2
    assert response.json()['routes'][0]['scope'] == 'unknown'
    assert client.post('/api/v1/channel-catalog/rank', json={'schemaVersion': 1, 'urls': ['http://127.0.0.1/private']}).status_code == 422
    assert client.post('/api/v1/channel-catalog/rank', json={'schemaVersion': 1, 'urls': [URL] * 201}).status_code == 422


def test_missing_geo_databases_degrades_to_unknown(tmp_path):
    assert network.resolve_address('8.8.8.8', tmp_path)['networkId'] == 'ZZ:*:*'
    assert network.resolve_address('127.0.0.1', tmp_path)['networkId'] == 'ZZ:*:*'
    assert network.resolve_address('::1', tmp_path)['networkId'] == 'ZZ:*:*'
    (tmp_path / 'network-db').mkdir()
    (tmp_path / 'network-db' / 'city.mmdb').write_bytes(b'invalid database')
    assert network.resolve_address('8.8.8.8', tmp_path)['networkId'] == 'ZZ:*:*'


def test_trusted_domestic_probe_can_approve_pending_route(tmp_path):
    ingest([{'name': 'News', 'url': URL, 'group': '中国 / 央视', 'source': 'test', 'blocked': False}], 'a' * 64, tmp_path)
    assert not process(tmp_path, verifier=lambda _: False)['published']
    result = {'id': 'a' * 32, 'url': URL, 'success': True, 'observation': 'probe'}
    profile = {**network.normalize_profile(CN), 'canApprove': True}
    first = network.ingest_probe_results([result], 'mainland-telecom', profile, tmp_path)
    assert network.ingest_probe_results([result], 'mainland-telecom', profile, tmp_path) == first
    assert process(tmp_path, limit=0)['published']
    assert ranks(tmp_path, CN)[URL]['score'] > .5
    assert ranks(tmp_path, US)[URL]['score'] == .5
    with pytest.raises(ValueError):
        network.ingest_probe_results([{**result, 'success': False}], 'mainland-telecom', profile, tmp_path)


def test_observer_node_cannot_publish_or_revive_retired_routes(tmp_path):
    ingest([{'name': 'News', 'url': URL, 'group': '中国 / 央视', 'source': 'test', 'blocked': False}], 'a' * 64, tmp_path)
    result = {'id': 'b' * 32, 'url': URL, 'success': True}
    profile = {**network.normalize_profile(CN), 'canApprove': False}
    network.ingest_probe_results([result], 'observer', profile, tmp_path)
    assert not process(tmp_path, limit=0)['published']
    ingest_events([{'id': 'c' * 32, 'url': URL, 'kind': 'retire'}], 'a' * 64, tmp_path)
    profile['canApprove'] = True
    assert network.ingest_probe_results([{**result, 'id': 'd' * 32}], 'observer', profile, tmp_path)['receipts'][0]['status'] == 'rejected'


def test_probe_http_requires_registered_secret(tmp_path, monkeypatch):
    seed(tmp_path)
    monkeypatch.setattr(catalog_inventory, 'DATA', tmp_path)
    config = tmp_path / 'probes.json'
    token = 'private-test-' + 'a' * 40
    config.write_text(__import__('json').dumps({'nodes': {'cn-node': {
        **CN, 'enabled': True, 'canApprove': True,
        'keySha256': hashlib.sha256(token.encode()).hexdigest(),
    }}}))
    monkeypatch.setenv('BOBTV_PROBE_CONFIG', str(config))
    app = FastAPI()
    app.include_router(network.router)
    monkeypatch.setattr(catalog_inventory, '_publish_changes', lambda: None)
    client = TestClient(app)
    path = '/api/v1/channel-catalog/probe-targets?nodeId=cn-node'
    assert client.get(path).status_code == 401
    headers = {'Authorization': 'Bearer ' + token}
    assert client.get(path, headers=headers).json()['urls']
    payload = {'schemaVersion': 1, 'nodeId': 'cn-node', 'results': [{'id': 'e' * 32, 'url': URL, 'success': False}]}
    assert client.post('/api/v1/channel-catalog/probe-results', json=payload).status_code == 401
    assert client.post('/api/v1/channel-catalog/probe-results', json=payload, headers=headers).status_code == 202
