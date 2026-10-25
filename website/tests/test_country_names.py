import copy
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).parents[1]))
from country_names import normalize_country_name, normalize_catalog_countries


def test_aliases_and_distinct_congos():
    assert {normalize_country_name(x) for x in ('United States', 'US', 'USA', '美國', '美国')} == {'美国'}
    assert normalize_country_name('Republic of the Congo') == '刚果（布）'
    assert normalize_country_name('Democratic Republic of the Congo') == '刚果（金）'
    assert normalize_country_name('Saint Kitts and Nevis') == '圣基茨和尼维斯'
    assert normalize_country_name('自定义地区') == '自定义地区'


def test_merges_country_and_nested_genres_preserving_every_channel_and_route():
    def category(id, name, parent=None):
        return dict(id=id, name=name, parentId=parent, sortOrder=0)
    payload = {'categories': [
        category('finance-en', '财经', 'news-en'),
        category('us-en', 'United States', 'world'),
        category('news-en', '新闻', 'us-en'),
        category('world', '国际'), category('us-zh', '美国', 'world'),
        category('news-zh', '新闻', 'us-zh'),
        category('uk', '英国', 'world'), category('uk-news', '新闻', 'uk'),
        category('domestic', '中国'), category('domestic-news', '新闻', 'domestic'),
    ], 'channels': [
        dict(id='a', categoryId='news-en', categoryIds=['news-en', 'news-zh'], routes=[{'url': 'one'}], epgId='guide-a'),
        dict(id='b', categoryId='finance-en', routes=[{'url': 'two'}], epgId='guide-b'),
        dict(id='c', categoryId='uk-news', routes=[{'url': 'three'}]),
    ]}
    before = copy.deepcopy(payload)
    result = normalize_catalog_countries(payload)
    assert payload == before
    by_id = {x['id']: x for x in result['categories']}
    assert 'us-en' not in by_id and 'news-en' not in by_id
    assert result['channels'][0]['categoryId'] == 'news-zh'
    assert result['channels'][0]['categoryIds'] == ['news-zh']
    assert by_id['finance-en']['parentId'] == 'news-zh'
    assert by_id['uk-news']['parentId'] == 'uk'
    assert by_id['domestic-news']['parentId'] == 'domestic'
    for original, updated in zip(payload['channels'], result['channels']):
        assert {k:v for k,v in original.items() if k not in ('categoryId', 'categoryIds')} == {k:v for k,v in updated.items() if k not in ('categoryId', 'categoryIds')}
    assert normalize_catalog_countries(result) == result
