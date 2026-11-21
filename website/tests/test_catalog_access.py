import pytest

from test_accounts import env, login
from catalog_access import install


@pytest.fixture
def protected(env, monkeypatch):
    client, _, _ = env
    monkeypatch.setenv('BOBTV_AUTHENTICATED_CATALOG', '1')
    install(client.app)
    for path in ['/api/v1/channel-catalog/manifest', '/api/v1/channel-catalog/snapshots/a.json.gz',
                 '/api/v1/sources', '/api/v1/epg/manifest', '/api/v1/demo/demo.bobtv']:
        client.app.get(path)(lambda: {'ok': True})
    return env


def test_guests_only_get_demo_and_auth_failures_are_not_cacheable(protected):
    client, _, _ = protected
    assert client.get('/api/v1/demo/demo.bobtv').status_code == 200
    for path in ['/api/v1/channel-catalog/manifest', '/api/v1/channel-catalog/snapshots/a.json.gz',
                 '/api/v1/sources', '/api/v1/epg/manifest']:
        result = client.get(path)
        assert result.status_code == 401
        assert result.headers['cache-control'] == 'private, no-store'


def test_members_use_regional_catalog_and_receive_authenticated_epg(protected):
    client, _, _ = protected
    _, headers = login(protected)
    assert client.get('/api/v1/channel-catalog/manifest', headers=headers).status_code == 403
    result = client.get('/api/v1/epg/manifest', headers=headers)
    assert result.status_code == 200
    assert result.headers['cache-control'] == 'private, no-store'


def test_verified_admin_can_audit_full_catalog(protected):
    client, _, _ = protected
    _, headers = login(protected, 'sunsx@outlook.com')
    result = client.get('/api/v1/channel-catalog/manifest', headers=headers)
    assert result.status_code == 200
    assert result.headers['cache-control'] == 'private, no-store'
