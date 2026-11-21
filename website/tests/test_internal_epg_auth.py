from urllib.request import Request

import pytest

import internal_epg_auth as auth


@pytest.fixture
def key(tmp_path, monkeypatch):
    path = tmp_path / 'read.key'
    path.write_bytes(b'r' * 32)
    monkeypatch.setenv('BOBTV_INTERNAL_EPG_KEY', str(path))
    return path


def test_both_nodes_sign_the_same_bounded_read_scope(key):
    path = '/api/v1/epg/snapshots/' + 'a' * 64 + '.json.gz'
    primary = auth.headers_for('https://bobtv.briconbric.com' + path, now=1000)
    mirror = auth.headers_for('https://cndrp.com/bobtv' + path, now=1000)
    assert primary == mirror and auth.authorized('GET', path, primary, now=1029)
    assert not auth.authorized('GET', path, primary, now=1031)
    assert not auth.authorized('GET', path, primary, now=969)
    assert not auth.authorized('HEAD', path, primary, now=1000)
    assert not auth.authorized('POST', path, primary, now=1000)
    assert not auth.authorized('GET', '/api/v1/epg/manifest', primary, now=1000)
    assert not auth.authorized('GET', '/api/v1/channel-catalog/manifest', primary, now=1000)
    assert not auth.authorized('GET', path, {**primary, auth.PROOF: '0' * 64}, now=1000)


@pytest.mark.parametrize('url', [
    'http://bobtv.briconbric.com/api/v1/epg/manifest',
    'https://evil.example/api/v1/epg/manifest',
    'https://bobtv.briconbric.com.evil.example/api/v1/epg/manifest',
    'https://user@bobtv.briconbric.com/api/v1/epg/manifest',
    'https://bobtv.briconbric.com:8443/api/v1/epg/manifest',
    'https://bobtv.briconbric.com/api/v1/epg/manifest?url=secret',
    'https://bobtv.briconbric.com/api/v1/channel-catalog/manifest',
    'https://cndrp.com/api/v1/epg/manifest',
])
def test_proofs_are_never_attached_to_other_destinations_or_privileges(key, url):
    assert auth.headers_for(url, now=1000) == {}
    request = Request(url)
    auth.ReadAuthHandler().https_request(request)
    assert not request.has_header(auth.PROOF.capitalize())


def test_missing_invalid_or_symlinked_key_never_authenticates(key):
    headers = auth.headers_for('https://bobtv.briconbric.com/api/v1/epg/manifest', now=1000)
    key.write_bytes(b'short')
    assert not auth.authorized('GET', '/api/v1/epg/manifest', headers, now=1000)
    key.unlink()
    assert auth.headers_for('https://bobtv.briconbric.com/api/v1/epg/manifest') == {}
    other = key.with_suffix('.other')
    other.write_bytes(b'r' * 32)
    key.symlink_to(other)
    assert not auth.authorized('GET', '/api/v1/epg/manifest', headers, now=1000)
