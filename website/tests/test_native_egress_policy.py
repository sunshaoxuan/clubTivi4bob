import sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).parents[2] / 'tools' / 'airplay'))
from egress_policy import server_or_local_url


@pytest.mark.parametrize('url', ['https://bobtv.briconbric.com/api/v1/egress/resource?cap=test',
    'http://127.0.0.1:8917/live.ts', 'http://192.168.1.20/live.ts', '/tmp/fixture.mp4'])
def test_native_inputs_accept_gateway_or_local(url):
    assert server_or_local_url(url) == url


@pytest.mark.parametrize('url', ['https://raw.githubusercontent.com/a/b/live.m3u8',
    'https://example.org/live.mp4', 'http://bobtv.briconbric.com/video',
    'https://bobtv.briconbric.com:49531/video', 'https://user:password@bobtv.briconbric.com/'])
def test_native_inputs_reject_public_direct_and_wrong_server(url):
    with pytest.raises(ValueError): server_or_local_url(url)
