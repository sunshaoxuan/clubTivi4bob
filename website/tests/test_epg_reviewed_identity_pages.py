"""Exact reviewed technical CMS paths; no external requests or approvals."""
import io
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_auto_search as search
from epg_ingest import EpgError

FAQ = 'https://www.chc2004.cn/2012/0917/655.html'
GUIDE = 'https://www.chc2004.cn/category/60.html'
PATH = ['中国', '数字']


def target():
    return {'id': 'channel-324ec8feb75c5ff464d80a35', 'name': 'CHC家庭影院',
            'countryCode': 'CN', 'regionCode': None, 'epgId': 'CHC家庭影院',
            'routes': [{'url': 'http://61.162.52.6:8088/newlive/live/hls/60/live.m3u8'}]}


def request():
    return search.plan(target(), PATH, None, 0)


@pytest.mark.parametrize('url', [FAQ, GUIDE])
def test_exact_scope_can_fetch_reviewed_public_cms_page(url):
    value = request()
    assert not search.candidate_allowed(url, [], 'identity')
    assert search.reviewed_identity_page(url, value)
    assert search.candidate_allowed(url, [], 'identity', request=value)
    assert search.candidate_has_target_context({'url': url, 'title': '频道订购技术说明'}, value)
    assert value['stage'] == 'identity'
    assert value['aliases'] == ['CHC家庭影院频道']
    assert 'Do not research EPG' in value['body']['instructions']
    assert target()['countryCode'] == 'CN'


@pytest.mark.parametrize('change', [
    {'id': 'another-channel'}, {'name': 'CHC动作电影'}, {'name': 'CHC家庭影院 +1'},
    {'countryCode': 'HK'}, {'regionCode': 'other'}, {'epgId': 'another'},
    {'routes': []}, {'routes': [{'url': 'https://stream.example.org/other.m3u8'}]},
    {'routes': [{'url': target()['routes'][0]['url'] + '?delay=3600'}]},
])
def test_catalogue_identity_or_exact_route_drift_removes_path_exception(change):
    value = search.plan({**target(), **change}, PATH, None, 0)
    assert not search.reviewed_identity_page(FAQ, value)
    assert not search.candidate_allowed(FAQ, [], 'identity', request=value)
    assert not value['aliases']


def test_category_change_removes_alias_and_path_exception():
    value = search.plan(target(), ['中国', '广播'], None, 0)
    assert not value['aliases']
    assert not search.candidate_allowed(FAQ, [], 'identity', request=value)


@pytest.mark.parametrize('url', [
    FAQ.replace('655.html', '656.html'), GUIDE.replace('60.html', '61.html'),
    FAQ + '?download=1', FAQ.replace('https://', 'http://'),
    'https://www.chc2004.cn/news/655.html',
    'https://www.chc2004.cn/login/655.html',
    'https://www.chc2004.cn/schedule/655.xml',
    'https://www.chc2004.cn/epg/table.json',
    'https://www.chc2004.cn/homemov/',
    'https://www.chc2004.cn/catid/72',
    'https://127.0.0.1/2012/0917/655.html',
])
def test_no_general_cms_programme_media_or_network_safety_expansion(url):
    value = request()
    value['reviewedIdentityPages'] = [url]  # Untrusted custom allowlists have no effect.
    assert not search.candidate_allowed(url, [], 'identity', request=value)


def test_domain_restriction_still_applies_to_reviewed_page():
    assert not search.candidate_allowed(FAQ, ['example.org'], 'identity', request=request())


def test_existing_technical_playlist_path_gets_no_reviewed_page_exception():
    url = 'https://raw.githubusercontent.com/yoursmile66/TVBox/main/live.txt'
    value = request()
    assert not search.reviewed_identity_page(url, value)
    # The pre-existing /live.txt technical rule remains unchanged.
    assert search.candidate_allowed(url, [], 'identity')
    assert not search.candidate_allowed(url, ['chc2004.cn'], 'identity', request=value)


def test_identity_page_exception_does_not_authorize_programme_phase():
    value = request()
    assert not search.candidate_allowed(FAQ, [], 'xmltv', request=value)
    value['stage'] = 'official_schedule'
    assert not search.reviewed_identity_page(FAQ, value)
    assert not search.candidate_allowed(FAQ, [], 'official_schedule', request=value)


@pytest.mark.parametrize('change', [{'catalogueContext': None}, {'catalogRoutes': None},
    {'channelId': []}, {'channelId': None}, {'fullName': 'CHC动作电影'},
    {'catalogRoutes': [None]}, {'catalogRoutes': [{}]}])
def test_invalid_request_context_does_not_gain_access(change):
    assert not search.candidate_allowed(FAQ, [], 'identity', request={**request(), **change})


def test_bounded_check_retains_target_text_and_does_not_approve_identity():
    raw = '技术说明：CHC家庭影院、CHC动作电影、CHC影迷电影为不同频道。'.encode()
    class Response(io.BytesIO):
        code = 200
        headers = {'Content-Type': 'text/html', 'Content-Length': str(len(raw))}
        def geturl(self):
            return FAQ
        def read1(self, size):
            return self.read(size)
    class Opener:
        def open(self, req, timeout):
            assert req.full_url == FAQ and req.method == 'GET' and timeout == 6
            return Response(raw)
    result = search.check_candidate(FAQ, request(), opener=Opener())
    assert result['result'] == 'partial_named_identity_evidence'
    assert result['bodyBytes'] == len(raw)
    assert result['linkedRouteSha256'] == []
    assert 'approved' not in result


def test_reject_before_opening_for_different_target():
    value = search.plan({**target(), 'id': 'different'}, PATH, None, 0)
    class Opener:
        def open(self, *_args, **_kwargs):
            pytest.fail('must not make a request')
    with pytest.raises(EpgError, match='auto_search_candidate_not_allowed'):
        search.check_candidate(FAQ, value, opener=Opener())


def pts_target():
    return {'id': 'channel-c30099894d43d43966e2b684', 'name': '公視',
            'countryCode': None, 'regionCode': None, 'epgId': None,
            'routes': [{'url': 'http://211.72.174.95:8116/0.ts'}]}


def test_pts_channel_table_exception_preserves_unknown_country():
    value = search.plan(pts_target(), ['国际', '台湾'], None, 0)
    url = 'https://www.pts.org.tw/ptsfamily'
    assert search.candidate_allowed(url, [], 'identity', request=value)
    assert not search.candidate_allowed(url, [], 'identity')
    assert value['catalogueContext']['countryCode'] is None
    assert value['stage'] == 'identity'
    assert value['aliases'] == ['公共電視主頻']
    assert value['primaryDomains'] == ['pts.org.tw']
    assert search.candidate_has_target_context({'url': url, 'title': '有線電視頻位表'}, value)
    assert pts_target()['countryCode'] is None


@pytest.mark.parametrize('change', [
    {'id': 'another-pts'}, {'name': '公視台語台'}, {'name': '公視 +1'},
    {'countryCode': 'TW'}, {'countryCode': 'CN'}, {'regionCode': 'TW-TPE'},
    {'epgId': 'PTS'}, {'routes': []},
    {'routes': [{'url': 'http://211.72.174.95:8115/0.ts'}]},
])
def test_pts_identity_or_route_drift_invalidates_hint_and_exception(change):
    value = search.plan({**pts_target(), **change}, ['国际', '台湾'], None, 0)
    assert not value['aliases']
    assert not search.candidate_allowed('https://www.pts.org.tw/ptsfamily', [], 'identity', request=value)


@pytest.mark.parametrize('url', [
    'https://www.pts.org.tw/ptsfamily/other',
    'https://www.pts.org.tw/ptsfamily?feed=other',
    'https://www.pts.org.tw/zh_tw/pr/latestnews/a-story',
    'https://www.pts.org.tw/epg/table.json',
    'https://www.pts.org.tw/schedule/table.xml',
])
def test_pts_path_exception_does_not_extend_to_other_content(url):
    value = search.plan(pts_target(), ['国际', '台湾'], None, 0)
    assert not search.candidate_allowed(url, [], 'identity', request=value)


def test_pts_category_change_invalidates_hint_and_path_exception():
    value = search.plan(pts_target(), ['中国', '数字'], None, 0)
    assert not value['aliases']
    assert not search.candidate_allowed('https://www.pts.org.tw/ptsfamily', [], 'identity', request=value)


def test_chc_and_pts_reviewed_page_scopes_cannot_cross():
    pts = search.plan(pts_target(), ['国际', '台湾'], None, 0)
    assert not search.candidate_allowed(FAQ, [], 'identity', request=pts)
    assert not search.candidate_allowed('https://www.pts.org.tw/ptsfamily', [], 'identity', request=request())


@pytest.mark.parametrize('text', ['公視固定於13頻道 臺語台固定於14頻道',
                               '公視 固定於 13 頻道；臺語台固定於14頻道'])
def test_reviewed_pts_service_marker_keeps_real_text_without_generic_short_name_matching(text):
    value = search.plan(pts_target(), ['国际', '台湾'], None, 0)
    assert search.inspect_text(text, value)['result'] == 'no_selected_identity_text'
    result = search.inspect_text(text, value, source_url='https://www.pts.org.tw/ptsfamily')
    assert result['result'] == 'partial_named_identity_evidence'
    assert result['selectedNameExcerpts'] == [text]
    assert 'identityApproved' not in result


@pytest.mark.parametrize('text', ['臺語台固定於14頻道', '小公視 121頻道',
                               '財團法人公共電視文化事業基金會', '公視固定於14頻道',
                               '公視曾在13頻道', '公視'])
def test_related_names_numbers_and_organizational_footer_are_not_pts_service_marker(text):
    value = search.plan(pts_target(), ['国际', '台湾'], None, 0)
    assert search.inspect_text(text, value, source_url='https://www.pts.org.tw/ptsfamily')['result'] == 'no_selected_identity_text'


@pytest.mark.parametrize('url', [None, 'https://other.example.org/profile',
                               'https://www.pts.org.tw/ptsfamily/other', FAQ])
def test_marker_cannot_cross_page_or_target_scope(url):
    value = search.plan(pts_target(), ['国际', '台湾'], None, 0)
    assert search.inspect_text('公視固定於13頻道', value, source_url=url)['result'] == 'no_selected_identity_text'
    assert search.inspect_text('公視固定於13頻道', request(), source_url=url)['result'] == 'no_selected_identity_text'


def test_marker_invalidated_by_route_and_country_drift():
    for change in ({'countryCode': 'TW'}, {'routes': []}):
        value = search.plan({**pts_target(), **change}, ['国际', '台湾'], None, 0)
        assert search.inspect_text('公視固定於13頻道', value, source_url='https://www.pts.org.tw/ptsfamily')['result'] == 'no_selected_identity_text'
