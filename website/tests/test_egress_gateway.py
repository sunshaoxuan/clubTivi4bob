import io
import json
import sys
import time
from email.message import Message
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).parents[1]))
import egress_gateway as gateway
import catalog_inventory
from process_channel_inventory import _public_socket, process

URL = 'https://media.example.org/live/master.m3u8'


class Upstream(io.BytesIO):
    def __init__(self, content, url=URL, code=200, mime='video/mp2t', **headers):
        super().__init__(content)
        self.url, self.code = url, code
        self.headers = Message()
        self.headers['Content-Type'] = mime
        for key, value in headers.items(): self.headers[key] = value


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(gateway, 'DATA', tmp_path)
    gateway._rates.clear()
    gateway._cache.clear()
    gateway._cache_bytes = 0
    catalog_inventory.ingest([{'name': 'Test', 'url': URL, 'group': '中国 / 央视',
        'source': 'test', 'blocked': False}], 'a' * 64, tmp_path)
    process(tmp_path, verifier=lambda _: True)
    app = FastAPI()
    app.include_router(gateway.router)
    return TestClient(app)


def test_only_reviewed_routes_can_open_media(client, monkeypatch):
    calls = []
    monkeypatch.setattr(gateway, 'upstream', lambda url, *a: calls.append(url) or Upstream(b'G' * 9000))
    response = client.get('/api/v1/egress/resource', params={'url': URL, 'kind': 'media'})
    assert response.status_code == 200 and response.content == b'G' * 9000
    assert response.headers['x-accel-buffering'] == 'no'
    denied = client.get('/api/v1/egress/resource', params={'url': 'https://example.org/secret', 'kind': 'media'})
    assert denied.status_code == 403
    assert calls == [URL]


def test_hls_rewrites_variants_audio_subtitles_keys_maps_and_segments(client, monkeypatch):
    playlist = '''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,URI="audio/live.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,URI="https://sub.example.org/sub.m3u8"
#EXT-X-KEY:METHOD=AES-128,URI="https://key.example.org/key"
#EXT-X-MAP:URI="init.mp4"
#EXT-X-PART:DURATION=0.3,URI="part.m4s"
#EXT-X-PRELOAD-HINT:TYPE=PART,URI="next.m4s"
#EXT-X-STREAM-INF:BANDWIDTH=2000000
video/live.m3u8
'''
    monkeypatch.setattr(gateway, 'upstream', lambda *a: Upstream(playlist.encode(), mime='application/vnd.apple.mpegurl'))
    response = client.get('/api/v1/egress/resource', params={'url': URL, 'kind': 'media'})
    assert response.status_code == 200
    text = response.text
    assert 'https://sub.example.org' not in text and 'https://key.example.org' not in text
    urls = __import__('re').findall(r'https://bobtv.briconbric.com/[^"\s]+', text)
    assert len(urls) == 7
    decoded = [gateway.verify_child(parse_qs(urlsplit(url).query)['cap'][0]) for url in urls]
    assert decoded[0]['url'] == 'https://media.example.org/live/audio/live.m3u8'
    assert decoded[-1]['url'] == 'https://media.example.org/live/video/live.m3u8'
    assert all(value['root'] == URL for value in decoded)


def test_capability_tamper_expiry_and_root_retirement(client):
    child = gateway.sign_child('https://other.example.org/segment.ts', URL)
    token = parse_qs(urlsplit(child).query)['cap'][0]
    with pytest.raises(ValueError): gateway.verify_child(token + 'f')
    with pytest.raises(ValueError): gateway.verify_child(token, now=int(time.time()) + 13 * 3600)
    catalog_inventory.ingest_events([{'id': 'b' * 32, 'kind': 'retire', 'url': URL}], 'c' * 64, gateway.DATA)
    with pytest.raises(ValueError): gateway.verify_child(token)


def test_children_keep_required_headers_without_range(client):
    text = gateway.rewrite_hls('#EXTM3U\n#EXTINF:5,\nseg.ts\n', URL, URL,
        {'referer': 'https://tv.example.org/'})
    token = parse_qs(urlsplit(text.splitlines()[-1]).query)['cap'][0]
    assert gateway.verify_child(token)['headers'] == {'referer': 'https://tv.example.org/'}


@pytest.mark.parametrize('text', [
    '#EXTM3U\n#EXT-X-KEY:URI=key.bin\n',
    '#EXTM3U\n{$host}/seg.ts\n',
    '#EXTM3U\n#EXT-X-CONTENT-STEERING:SERVER-URI="https://other.org/"\n',
    '#EXTM3U\nfile:///etc/passwd\n',
    '#EXTM3U\nrtsp://other.example.org/live\n',
])
def test_unsupported_indirection_fails_closed(client, text):
    with pytest.raises(ValueError): gateway.rewrite_hls(text, URL, URL)


def test_dns_rebinding_and_private_results_are_rejected(monkeypatch):
    monkeypatch.setattr('socket.getaddrinfo', lambda *a, **kw: [(2, 1, 6, '', ('127.0.0.1', 80))])
    with pytest.raises(ValueError): _public_socket('public.example.org', 80, 1, None)


def test_range_and_mime_streaming(client, monkeypatch):
    seen = []
    def fetch(url, headers, method):
        seen.append((headers, method))
        return Upstream(b'G' * 7000, code=206, **{'Content-Range': 'bytes 0-6999/99999'})
    monkeypatch.setattr(gateway, 'upstream', fetch)
    response = client.get('/api/v1/egress/resource', params={'url': URL, 'kind': 'media'}, headers={'Range': 'bytes=0-6999'})
    assert response.status_code == 206 and response.headers['content-range'] == 'bytes 0-6999/99999'
    assert seen[0][0]['range'] == 'bytes=0-6999'
    assert gateway.SLOTS.acquire(blocking=False)
    gateway.SLOTS.release()


def test_nonmedia_does_not_reach_native_manifest_parser(client, monkeypatch):
    monkeypatch.setattr(gateway, 'upstream', lambda *a: Upstream(b'<MPD><BaseURL>https://other.org</BaseURL></MPD>', mime='application/dash+xml'))
    assert client.get('/api/v1/egress/resource', params={'url': URL, 'kind': 'media'}).status_code == 502


def test_data_is_named_integration_only_and_auth_not_url(client, monkeypatch):
    seen = []
    def fetch(url, kind, headers, method, body):
        seen.append((url, headers, method, body))
        return b'{"ok":true}', 200, {'Content-Type': 'application/json'}
    monkeypatch.setattr(gateway, 'fetch_small', fetch)
    payload = {'url': 'https://api.themoviedb.org/3/tv/1', 'method': 'GET',
        'headers': {'Authorization': 'Bearer test-secret', 'Cookie': 'not-forwarded'}, 'body': ''}
    assert client.post('/api/v1/egress/data', json=payload).status_code == 200
    assert seen[0][1] == {'authorization': 'Bearer test-secret'}
    for url in ('http://api.themoviedb.org/3/tv/1', 'https://api.github.com/repos/a/b',
                'https://ccnode.briconbric.com:49531/v1/models', 'http://127.0.0.1:80/'):
        assert client.post('/api/v1/egress/data', json={**payload, 'url': url}).status_code == 403
    assert len(seen) == 1


def test_resource_cache_and_approved_auxiliary_hosts(client, monkeypatch):
    calls = []
    monkeypatch.setattr(gateway, 'fetch_small', lambda url, kind: calls.append(url) or (b'png', 200, {'Content-Type': 'image/png'}))
    url = 'https://image.tmdb.org/t/p/w500/a.png'
    for _ in range(2): assert client.get('/api/v1/egress/resource', params={'url': url, 'kind': 'image'}).status_code == 200
    assert len(calls) == 1
    assert gateway.approved('https://epg.zsdc.eu.org/t.xml.gz', 'epg')
    assert not gateway.approved('https://unreviewed.example.org/epg.xml', 'epg')


def test_capacity_failures_are_visible_not_direct_redirects(client):
    for _ in range(16): assert gateway.SLOTS.acquire(blocking=False)
    try:
        response = client.get('/api/v1/egress/resource', params={'url': URL, 'kind': 'media'})
        assert response.status_code == 503 and 'location' not in response.headers
    finally:
        for _ in range(16): gateway.SLOTS.release()


def test_dash_templates_base_urls_ranges_and_audio_are_rewritten(client, monkeypatch):
    source = b'''<MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><BaseURL>https://cdn.example.org/dash/</BaseURL>
    <Period><AdaptationSet><SegmentTemplate media="$RepresentationID$/$Number%05d$.m4s" initialization="$RepresentationID$/init.mp4"/>
    <Representation id="video1" bandwidth="500000"/><Representation id="audio1" bandwidth="64000"/>
    </AdaptationSet></Period></MPD>'''
    monkeypatch.setattr(gateway, 'upstream', lambda *a: Upstream(source, mime='application/dash+xml'))
    response = client.get('/api/v1/egress/resource', params={'url': URL, 'kind': 'media'})
    assert response.status_code == 200 and 'https://cdn.example.org' not in response.text
    from xml.etree import ElementTree as ET
    root = ET.fromstring(response.content)
    templates = root.findall('.//{*}SegmentTemplate')
    assert len(templates) == 2
    media = templates[0].get('media')
    assert '$RepresentationID$' in media and '$Number%05d$' in media
    from dash_relay import expand_template
    token = parse_qs(urlsplit(media).query)['cap'][0]
    payload = gateway.verify_child(token)
    assert expand_template(payload['url'], payload['variables'], {'r': 'video1', 'n': '00003'}) == 'https://cdn.example.org/dash/video1/00003.m4s'
    assert expand_template(payload['url'], payload['variables'], {'r': 'video.1', 'n': '3'}) == 'https://cdn.example.org/dash/video.1/00003.m4s'
    with pytest.raises(ValueError): expand_template(payload['url'], payload['variables'], {'r': '../secret', 'n': '3'})
    with pytest.raises(ValueError): expand_template(payload['url'], payload['variables'], {'r': '..', 'n': '3'})


@pytest.mark.parametrize('source', [
    b'<MPD><Period><AdaptationSet><Representation id="v"><ContentProtection/></Representation></AdaptationSet></Period></MPD>',
    b'<!DOCTYPE MPD [<!ENTITY x SYSTEM "http://127.0.0.1/secret">]><MPD/>',
    b'<MPD xmlns:xlink="http://www.w3.org/1999/xlink"><Period><AdaptationSet><Representation id="v"><SegmentTemplate xlink:href="https://secret.example.org/x"/></Representation></AdaptationSet></Period></MPD>',
])
def test_dash_drm_entities_and_xlink_are_rejected(client, monkeypatch, source):
    monkeypatch.setattr(gateway, 'upstream', lambda *a: Upstream(source, mime='application/dash+xml'))
    assert client.get('/api/v1/egress/resource', params={'url': URL, 'kind': 'media'}).status_code == 502
