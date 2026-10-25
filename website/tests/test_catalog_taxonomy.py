import copy
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).parents[1]))
from catalog_taxonomy import classified_path, normalize_catalog_taxonomy, apply_channel_paths


def test_unknown_geography_never_defaults_to_china():
    assert classified_path(['中国','其他','电影'], {}) == ['其他','待识别','电影']
    assert classified_path(['国际','未识别地区','音乐'], {}) == ['其他','待识别','音乐']
    assert classified_path(['其他','电影'], {'countryCode':'US'}) == ['其他','电影']


def test_radio_follows_structured_country_metadata_and_unknown_stays_pending():
    for code, expected in [('CN',['中国','广播']),('US',['国际','美国','广播']),
                           ('KW',['国际','科威特','广播']), (None,['其他','广播','待识别'])]:
        assert classified_path(['广播'], {'countryCode':code}) == expected
    assert classified_path(['国际','英国','新闻'], {}) == ['国际','英国','电视','新闻']
    assert classified_path(['国际','英国','音乐'], {'routes':[{'url':'https://radio.example/live.mp3'}]}) == ['国际','英国','广播']
    assert classified_path(['国际','英国','电视','音乐'], {'routes':[{'url':'https://radio.example/live.mp3'}]}) == ['国际','英国','电视','音乐']


def fixture():
    def cat(id,name,parent=None): return dict(id=id,name=name,parentId=parent,sortOrder=0)
    return {'schemaVersion':1,'version':'test','categories':[
        cat('cn','中国'),cat('other-cn','其他','cn'),cat('world','国际'),cat('us','美国','world'),
        cat('news','新闻','us'),cat('movie','电影','us'),cat('radio','广播'),cat('other','其他')],
        'channels':[
            dict(id='a',categoryId='other-cn',epgId='guide-a',routes=[dict(id='ra',url='https://example.org/a.m3u8')]),
            dict(id='b',categoryId='news',categoryIds=['news','movie'],epgId='guide-b',routes=[dict(id='rb',url='https://example.org/b.m3u8')]),
            dict(id='c',categoryId='radio',countryCode='US',routes=[dict(id='rc',url='https://example.org/c.aac')]),
        ]}


def path(payload,id):
    cats={c['id']:c for c in payload['categories']};out=[]
    while id:
        c=cats[id];out.insert(0,c['name']);id=c['parentId']
    return out


def test_normalization_is_idempotent_preserves_ids_routes_and_epg_and_aliases():
    original=fixture(); before=copy.deepcopy(original)
    result=normalize_catalog_taxonomy(original)
    assert original==before
    assert normalize_catalog_taxonomy(result)==result
    for old,new in zip(original['channels'],result['channels']):
        assert {k:v for k,v in old.items() if k not in ('categoryId','categoryIds')} == {k:v for k,v in new.items() if k not in ('categoryId','categoryIds')}
    assert path(result,result['channels'][0]['categoryId'])==['其他','待识别']
    assert path(result,result['channels'][1]['categoryId'])==['国际','美国','电视','新闻']
    assert [path(result,x) for x in result['channels'][1]['categoryIds']]==[['国际','美国','电视','新闻'],['国际','美国','电视','电影']]
    assert path(result,result['channels'][2]['categoryId'])==['国际','美国','广播']


def test_reviewed_move_preserves_every_channel_and_route():
    original=normalize_catalog_taxonomy(fixture());result=apply_channel_paths(original,{'a':['国际','科威特','广播']})
    assert path(result,result['channels'][0]['categoryId'])==['国际','科威特','广播']
    for old,new in zip(original['channels'],result['channels']):
        assert old['id']==new['id'] and old['routes']==new['routes'] and old.get('epgId')==new.get('epgId')
