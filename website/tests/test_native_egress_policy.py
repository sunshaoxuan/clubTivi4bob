import sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).parents[2] / 'tools' / 'airplay'))
from egress_policy import server_or_local_url


@pytest.mark.parametrize('url', ['https://bobtv.briconbric.com/api/v1/egress/resource?cap=test',
    'http://127.0.0.1:8917/live.ts', 'http://192.168.1.20/live.ts', '/tmp/fixture.mp4'])
def test_native_inputs_accept_gateway_or_local(url):
    assert server_or_local_url(url) == url


@pytest.mark.parametrize('url', ['https://cndrp.com/bobtv/video/live.m3u8',
    'https://user:password@bobtv.briconbric.com/', 'ftp://example.org/video'])
def test_native_inputs_reject_resource_node_and_invalid_video(url):
    with pytest.raises(ValueError): server_or_local_url(url)


@pytest.mark.parametrize('url', ['https://media.example.org/live.mp4',
    'http://media.example.org:8080/live.m3u8'])
def test_native_video_uses_direct_origin(url):
    assert server_or_local_url(url) == url
