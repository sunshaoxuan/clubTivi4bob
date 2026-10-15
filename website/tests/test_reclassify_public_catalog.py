from unittest.mock import patch

from reclassify_public_catalog import ai_path, first_logo


def decision(**updates):
    item = {
        'market': '中国', 'region': '中央', 'kind': 'television',
        'programType': '综合', 'confidence': .99,
        'evidence': 'Station identity confirmed by full name and logo.',
    }
    item.update(updates)
    return item


def test_central_radio_maps_even_when_region_says_central():
    assert ai_path(decision(kind='radio', region='中央')) == ['中国', '广播']


def test_province_suffix_and_special_autonomous_region_are_normalized():
    assert ai_path(decision(region='浙江省', programType='新闻')) == ['中国', '浙江', '新闻']
    assert ai_path(decision(region='广西壮族自治区', programType='法制')) == ['中国', '广西', '法治']


def test_cctv_specialty_genres_are_representable():
    assert ai_path(decision(region='央视', programType='农业农村')) == ['中国', '央视', '农业']
    assert ai_path(decision(region='央视', programType='军事')) == ['中国', '央视', '军事']
    assert ai_path(decision(region='央视', programType='时尚')) == ['中国', '央视', '时尚']


def test_hong_kong_alias_and_english_market_are_normalized():
    assert ai_path(decision(market='香港特别行政区', region='', programType='资讯')) == [
        '国际', '香港', '新闻',
    ]


def test_uncertain_or_unmapped_decisions_remain_unclassified():
    assert ai_path(decision(confidence=.89)) is None
    assert ai_path(decision(region='火星', confidence=.99)) is None
    assert ai_path(decision(abstain=True)) is None


def test_logo_fetch_tries_next_candidate_after_a_dead_url():
    with patch('reclassify_public_catalog.logo_data', side_effect=[None, 'data:image/png;base64,ok']) as fetch:
        assert first_logo(['https://dead.example/logo.png', 'https://live.example/logo.png']) == 'data:image/png;base64,ok'
        assert fetch.call_count == 2

