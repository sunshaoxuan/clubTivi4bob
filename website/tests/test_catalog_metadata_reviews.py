import copy
import hashlib
import json
from pathlib import Path
import sys
import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
from catalog_metadata_reviews import apply_reviews


def fixture(tmp_path):
    channel = {'id': 'fixture', 'name': 'Fixture exact station', 'epgId': None,
        'countryCode': 'CN', 'regionCode': None, 'routes': [{'url': 'https://fixture.example.org/fm.m3u8'}]}
    review = {'expectedIdentity': {key: channel[key] for key in ('id','name','epgId','countryCode','regionCode')},
        'routeSha256': [hashlib.sha256(channel['routes'][0]['url'].encode()).hexdigest()],
        'countryCode': 'TW', 'regionCode': None, 'reviewedAt': '2026-10-17T00:00:00Z',
        'evidenceUrls': ['https://fixture.example.org/identity']}
    path = tmp_path / 'reviews.json'
    path.write_text(json.dumps({'schemaVersion': 1, 'reviews': [review]}))
    return channel, path


def test_only_exact_identity_and_exact_routes_are_corrected(tmp_path):
    channel, path = fixture(tmp_path)
    before = copy.deepcopy(channel)
    assert apply_reviews([channel], path) == ['fixture']
    assert channel == {**before, 'countryCode': 'TW'}
    assert apply_reviews([channel], path) == []


@pytest.mark.parametrize('change', ['id', 'name', 'epgId', 'countryCode', 'regionCode', 'route', 'extra-route'])
def test_changed_identity_or_unreviewed_route_cannot_inherit_correction(tmp_path, change):
    channel, path = fixture(tmp_path)
    if change == 'route': channel['routes'][0]['url'] = 'https://else.example.org/fm.m3u8'
    elif change == 'extra-route': channel['routes'].append({'url': 'https://else.example.org/fm.m3u8'})
    else: channel[change] = 'changed'
    before = copy.deepcopy(channel)
    assert apply_reviews([channel], path) == []
    assert channel == before


def test_catalogue_publisher_preserves_reviewed_id_routes_and_classification(tmp_path, monkeypatch):
    import catalog_metadata_reviews
    from publish_channel_catalog import publish
    channel, review_path = fixture(tmp_path)
    channel.update(categoryId='category-fixture', sortOrder=1, logoUrl=None)
    channel['routes'][0].update(id='route-fixture', source='official',
        lastPlayableAt=None, healthScore=0.8)
    before = copy.deepcopy(channel)
    actual_apply = catalog_metadata_reviews.apply_reviews
    monkeypatch.setattr(catalog_metadata_reviews, 'apply_reviews',
        lambda channels: actual_apply(channels, review_path))
    payload = {'schemaVersion': 1, 'version': '2026-10-17T00:00:00Z',
        'categories': [{'id':'category-fixture','parentId':None,'name':'广播','sortOrder':1}],
        'channels': [channel]}
    publish(payload, tmp_path / 'published')
    assert payload['channels'] == [{**before, 'countryCode': 'TW'}]


def test_review_registry_taichung_is_exact_and_retains_two_taipei_reviews():
    import catalog_metadata_reviews
    records=json.loads(catalog_metadata_reviews.REVIEWS.read_text())['reviews']
    assert {r['expectedIdentity']['id'] for r in records} == {
        'channel-660f616f2daf011b430dc9be','channel-d0e7b4315a733439fc14a5e1',
        'channel-3b9b9e4b1a2e3ec6866d1bc3','channel-8ca60a553c5962c14fb43430',
        'channel-471f1b9c367d9dd0c158035c','channel-0cb2510668eacd72e36302d9',
        'channel-f9575f6ac5f72cf9df249366','channel-0c91ed6a2aed18bdb72391a4'}
    row=next(r for r in records if r['expectedIdentity']['id']=='channel-3b9b9e4b1a2e3ec6866d1bc3')
    assert row['expectedIdentity']=={'id':'channel-3b9b9e4b1a2e3ec6866d1bc3',
        'name':'警察广播台中分台','epgId':None,'countryCode':'CN','regionCode':None}
    assert row['countryCode']=='TW' and row['regionCode'] is None
    assert row['routeSha256']==['02d8acb043ad07df6a71807373e7b5726567a10e8f3ae4cf8941e19ffa2d31cc']


def test_commercial_taichung_radio_review_is_separate_from_police_station():
    import catalog_metadata_reviews
    from route_identity import canonical_route_url
    records=json.loads(catalog_metadata_reviews.REVIEWS.read_text())['reviews']
    row=next(r for r in records if r['expectedIdentity']['id']=='channel-8ca60a553c5962c14fb43430')
    assert row['expectedIdentity']=={'id':'channel-8ca60a553c5962c14fb43430',
        'name':'台中广播电台','epgId':None,'countryCode':'CN','regionCode':None}
    assert row['countryCode']=='TW' and row['regionCode'] is None
    assert row['routeSha256']==['d6603f37edadf51c5b05b48a7f441186d9d63ca3ccae9ed588e8af6a9e3ffdb3']
    assert canonical_route_url('http://211.20.119.101:8081')=='http://211.20.119.101:8081/'


def test_family977_review_is_exact_and_cannot_change_bravo_or_other_routes():
    import catalog_metadata_reviews
    records=json.loads(catalog_metadata_reviews.REVIEWS.read_text())['reviews']
    row=next(r for r in records if r['expectedIdentity']['id']=='channel-471f1b9c367d9dd0c158035c')
    assert row['expectedIdentity']=={'id':'channel-471f1b9c367d9dd0c158035c',
        'name':'台中古典音乐台','epgId':None,'countryCode':'CN','regionCode':None}
    assert row['countryCode']=='TW' and row['regionCode'] is None
    target={**row['expectedIdentity'],'routes':[{'url':'https://onair.family977.com.tw:8977/live.mp3'}]}
    assert apply_reviews([target])==[target['id']]
    assert target['countryCode']=='TW'
    changed={**row['expectedIdentity'],'routes':[{'url':'https://unreviewed.example.org/bravo.mp3'}]}
    assert apply_reviews([changed])==[] and changed['countryCode']=='CN'


def test_rthk3_review_has_exact_english_radio_route_not_tv_or_putonghua():
    import catalog_metadata_reviews
    records=json.loads(catalog_metadata_reviews.REVIEWS.read_text())['reviews']
    row=next(r for r in records if r['expectedIdentity']['id']=='channel-0cb2510668eacd72e36302d9')
    assert row['expectedIdentity']=={'id':'channel-0cb2510668eacd72e36302d9',
        'name':'RTHK3','epgId':None,'countryCode':'CN','regionCode':None}
    assert row['countryCode']=='HK'
    target={**row['expectedIdentity'],'routes':[{'url':'https://rthkradio3-live.akamaized.net/hls/live/2040079/radio3/master.m3u8'}]}
    assert apply_reviews([target])==[target['id']] and target['countryCode']=='HK'
    for other in ('https://rthktv31-live.akamaized.net/hls/live/2036818/RTHKTV31/master.m3u8',
                  'https://rthkradiopth-live.akamaized.net/hls/live/2040082/radiopth/master.m3u8'):
        changed={**row['expectedIdentity'],'routes':[{'url':other}]}
        assert apply_reviews([changed])==[] and changed['countryCode']=='CN'


def test_rthk_putonghua_review_cannot_inherit_radio3_or_tv_identity():
    import catalog_metadata_reviews
    records=json.loads(catalog_metadata_reviews.REVIEWS.read_text())['reviews']
    row=next(r for r in records if r['expectedIdentity']['id']=='channel-f9575f6ac5f72cf9df249366')
    assert row['expectedIdentity']=={'id':'channel-f9575f6ac5f72cf9df249366',
        'name':'RTHK普通话','epgId':None,'countryCode':'CN','regionCode':None}
    assert row['countryCode']=='HK'
    route='https://rthkradiopth-live.akamaized.net/hls/live/2040082/radiopth/master.m3u8'
    target={**row['expectedIdentity'],'routes':[{'url':route}]}
    assert apply_reviews([target])==[target['id']] and target['countryCode']=='HK'
    for other in ('https://rthkradio3-live.akamaized.net/hls/live/2040079/radio3/master.m3u8',
                  'https://rthktv31-live.akamaized.net/hls/live/2036818/RTHKTV31/master.m3u8'):
        changed={**row['expectedIdentity'],'routes':[{'url':other}]}
        assert apply_reviews([changed])==[] and changed['countryCode']=='CN'


def test_bbc_dance_geography_is_bound_to_one_exact_original_route():
    import catalog_metadata_reviews
    row=next(r for r in json.loads(catalog_metadata_reviews.REVIEWS.read_text())['reviews']
             if r['expectedIdentity']['id']=='channel-0c91ed6a2aed18bdb72391a4')
    assert row['countryCode']=='GB'
    route='http://as-hls-ww-live.akamaized.net/pool_62063831/live/ww/bbc_radio_one_dance/bbc_radio_one_dance.isml/bbc_radio_one_dance-audio%3d96000.norewind.m3u8'
    target={**row['expectedIdentity'],'routes':[{'url':route}]}
    assert apply_reviews([target])==[target['id']] and target['countryCode']=='GB'
    for other in (route.replace('one_dance','one_anthems'),route.replace('http:','https:'),
                  route.replace('96000','320000')):
        changed={**row['expectedIdentity'],'routes':[{'url':other}]}
        assert apply_reviews([changed])==[] and changed['countryCode']=='CN'
