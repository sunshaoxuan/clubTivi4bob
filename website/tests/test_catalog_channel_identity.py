import sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))

from catalog_channel_identity import coalesce_classification_variants
from catalog_inventory import database, ingest
from process_channel_inventory import process
from test_channel_inventory import snapshot


def fixture():
    categories = {
        'world': {'id': 'world', 'name': '国际', 'parentId': None},
        'my': {'id': 'my', 'name': '马来西亚', 'parentId': 'world'},
        'drama': {'id': 'drama', 'name': '剧集', 'parentId': 'my'},
        'movie': {'id': 'movie', 'name': '电影', 'parentId': 'my'},
    }
    channels = [
        {'id': 'old-drama', 'name': 'Astro AOD', 'categoryId': 'drama',
         'sortOrder': 0, 'epgId': None, 'regionCode': None, 'countryCode': None,
         'routes': [{'id': 'r1', 'url': 'https://media.example.org/aod'}]},
        {'id': 'old-movie', 'name': 'Astro AOD', 'categoryId': 'movie',
         'sortOrder': 1, 'epgId': None, 'regionCode': None, 'countryCode': None,
         'routes': [{'id': 'r2', 'url': 'https://media.example.org/aod2'}]},
    ]
    return channels, categories


def test_genre_only_split_coalesces_without_losing_routes_or_mutating_input():
    channels, categories = fixture()
    actual = coalesce_classification_variants(channels, categories)
    assert len(actual) == 1 and actual[0]['id'] == 'old-drama'
    assert {r['id'] for r in actual[0]['routes']} == {'r1', 'r2'}
    assert len(channels) == 2 and len(channels[0]['routes']) == 1


@pytest.mark.parametrize(('field', 'one', 'two'), [
    ('regionCode', 'east', 'west'), ('epgId', 'aod311', 'aod351'),
    ('regionCode', None, 'east'), ('epgId', None, 'aod311'),
    ('countryCode', 'MY', 'SG'), ('name', 'Astro AOD', 'Astro AOD +1'),
    ('name', 'Astro AOD', 'Astro AOD 4K'), ('name', 'CCTV-5', 'CCTV-5+'),
    ('mergeId', 'manual-one', 'manual-two'),
])
def test_identity_or_manual_distinctions_remain_separate(field, one, two):
    channels, categories = fixture()
    channels[0][field], channels[1][field] = one, two
    assert len(coalesce_classification_variants(channels, categories)) == 2


def test_same_name_in_different_countries_is_not_merged():
    channels, categories = fixture()
    categories['sg'] = {'id': 'sg', 'name': '新加坡', 'parentId': 'world'}
    categories['movie']['parentId'] = 'sg'
    assert len(coalesce_classification_variants(channels, categories)) == 2


def test_retained_ids_in_same_country_without_genre_are_coalesced():
    channels, categories = fixture()
    for channel in channels:
        channel['categoryId'] = 'my'
    assert len(coalesce_classification_variants(channels, categories)) == 1


def test_domestic_same_name_in_different_provinces_is_separate():
    channels, _ = fixture()
    categories = {'cn': {'id': 'cn', 'name': '中国', 'parentId': None},
        'east': {'id': 'east', 'name': '上海', 'parentId': 'cn'},
        'west': {'id': 'west', 'name': '重庆', 'parentId': 'cn'}}
    channels[0]['categoryId'], channels[1]['categoryId'] = 'east', 'west'
    assert len(coalesce_classification_variants(channels, categories)) == 2
    channels[1]['categoryId'] = 'east'
    assert len(coalesce_classification_variants(channels, categories)) == 1


def test_unknown_country_and_extra_local_hierarchy_fail_closed():
    channels, categories = fixture()
    categories['my']['name'] = '未识别地区'
    assert len(coalesce_classification_variants(channels, categories)) == 2
    categories['my']['name'] = '马来西亚'
    categories['local'] = {'id': 'local', 'name': '当地版本', 'parentId': 'my'}
    categories['movie']['parentId'] = 'local'
    assert len(coalesce_classification_variants(channels, categories)) == 2


def test_explicit_identity_decision_is_preserved():
    channels, categories = fixture()
    assert len(coalesce_classification_variants(channels, categories,
        protected_urls={channels[1]['routes'][0]['url']})) == 2


def test_all_genre_memberships_are_preserved():
    channels, categories = fixture()
    merged = coalesce_classification_variants(channels, categories)
    assert merged[0]['categoryIds'] == ['drama', 'movie']


def test_genre_change_reuses_previous_id_by_route_and_is_idempotent():
    channels, categories = fixture()
    previous = {'categories': list(categories.values()), 'channels': [channels[0]]}
    moved = [{**channels[0], 'id': 'new-genre-id', 'categoryId': 'movie'}]
    first = coalesce_classification_variants(moved, categories, previous=previous)
    assert first[0]['id'] == 'old-drama'
    assert coalesce_classification_variants(first, categories, previous=previous) == first
    disjoint = [{**moved[0], 'routes': channels[1]['routes']}]
    assert coalesce_classification_variants(disjoint, categories, previous=previous)[0]['id'] == 'new-genre-id'


def test_real_publication_coalesces_automatic_genres_and_keeps_id_after_move(tmp_path):
    rows = [{'name': 'Astro AOD', 'group': '国际 / 马来西亚 / ' + genre,
             'url': 'https://media.example.org/' + suffix,
             'source': 'test-public', 'blocked': False, 'playableAt': None}
            for genre, suffix in [('剧集', 'aod'), ('电影', 'aod2')]]
    ingest(rows, 'a' * 64, tmp_path)
    with database(tmp_path) as connection:
        connection.execute('UPDATE routes SET manual_category=1')
    assert process(tmp_path, verifier=lambda _: True)['published']
    first = snapshot(tmp_path)
    assert len(first['channels']) == 1
    assert len(first['channels'][0]['routes']) == 2
    assert len(first['channels'][0]['categoryIds']) == 2
    with database(tmp_path) as connection:
        assert connection.execute('SELECT COUNT(DISTINCT group_name) FROM routes').fetchone()[0] == 2
        assert connection.execute('SELECT MIN(manual_category) FROM routes').fetchone()[0] == 1
    with database(tmp_path) as connection:
        connection.execute("UPDATE routes SET group_name='国际 / 马来西亚 / 电影'")
    process(tmp_path, limit=0)
    second = snapshot(tmp_path)
    assert second['channels'][0]['id'] == first['channels'][0]['id']
    assert len(second['channels'][0]['routes']) == 2
