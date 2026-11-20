"""Authored contract fixtures, without live station approvals or network calls."""
import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).parents[1]))
import pytest
import epg_rakuten as r
from epg_ingest import EpgError

NOW = int(datetime(2026,11,15,12,tzinfo=timezone.utc).timestamp())
SOURCE = {'url': r.API, 'marketCode': 'uk', 'calendarTimezone': 'Europe/London', 'redirectUrls': []}

def event(identity, start, end, movie='fixture-film'):
    return {'id': str(identity), 'title': 'Fixture film', 'starts_at': start,
        'ends_at': end, 'movie_id': movie, 'is_live': False}

def payload(events=None):
    return {'data':[{'id':'action-rakuten-tv','numerical_id':6065,'title':'Fixture Action',
        'live_programs':events if events is not None else [
            event(1,'2026-11-15T11:00:00Z','2026-11-15T13:00:00Z'),
            event(2,'2026-11-15T13:00:01Z','2026-11-15T15:00:00Z')]}],
        'bobtvRequest':{'marketCode':'uk'}}

def parse(value):return r.parse_schedule(json.dumps(value).encode(),SOURCE,NOW)

def test_false_is_live_keeps_current_movie_and_identity_and_source_ids():
    out=parse(payload());assert out['quality']['currentAndFutureChannels']==1
    assert out['programmes'][0]['originalChannelId']=='rakuten:uk:6065'
    assert out['programmes'][0]['sourceEventId']=='1'
    assert out['programmes'][0]['movieId']=='fixture-film'

def test_same_slug_different_market_service_is_rejected():
    value=payload();value['data'][0]['numerical_id']=6066
    with pytest.raises(EpgError,match='market_identity_mismatch'):parse(value)

def test_conflicting_ids_and_both_sides_of_overlaps_are_quarantined():
    value=payload([event(1,'2026-11-15T11:00:00Z','2026-11-15T13:00:00Z'),
        event(2,'2026-11-15T12:00:00Z','2026-11-15T14:00:00Z')])
    out=parse(value);assert out['programmes']==[]
    assert out['quality']['rejected']['overlapping_programme']==2

def test_naive_times_are_not_interpreted_using_server_timezone():
    value=payload();value['data'][0]['live_programs'][0]['starts_at']='2026-11-15T11:00:00'
    assert parse(value)['quality']['rejected']['invalid_programme']==1

def test_missing_movie_id_stays_unresolved_without_dropping_schedule():
    value=payload();value['data'][0]['live_programs'][0]['movie_id']=None
    assert parse(value)['programmes'][0]['movieId'] is None

def test_missing_programme_field_is_not_a_successful_schedule():
    value=payload();del value['data'][0]['live_programs']
    out=parse(value);assert out['quality']['acceptedProgrammes']==0
    assert out['quality']['rejected']['schedule_field_absent']==1

def test_calendar_window_handles_both_dst_transitions():
    for date,hours in [('2026-03-29T12:00:00+00:00',47),('2026-10-25T12:00:00+00:00',49)]:
        a,b=r.window(SOURCE,int(datetime.fromisoformat(date).timestamp()))
        assert (r.timestamp(b)-r.timestamp(a))/3600==hours

def test_pagination_is_complete_and_published_projection_omits_rich_content():
    calls=[]
    def fetch(source):
        calls.append(source['url']);page=len(calls)
        row=payload()['data'][0] if page==1 else {'id':'fixture-other','numerical_id':99999,'title':'Other','live_programs':[]}
        row=copy.deepcopy(row);row['description']='not in factual cache'
        body=json.dumps({'data':[row],'meta':{'pagination':{'page':page,'count':2,'total_pages':2}}}).encode()
        return body,{'fetchedAtUtc':NOW}
    body,receipt=r.fetch_schedule(SOURCE,NOW,fetch)
    assert len(calls)==2 and receipt['channelsFetched']==2
    assert b'not in factual cache' not in body
    assert 'epg_starts_at=' in calls[0] and 'epg_ends_at=' in calls[0]

def test_pagination_duplicates_fail_and_cannot_replace_last_good_data():
    def fetch(source):
        from urllib.parse import parse_qs,urlsplit
        page=int(parse_qs(urlsplit(source['url']).query)['page'][0])
        return json.dumps({'data':payload()['data'],'meta':{'pagination':{'page':page,'count':2,'total_pages':2}}}).encode(),{}
    with pytest.raises(EpgError,match='ambiguous_pagination'):r.fetch_schedule(SOURCE,NOW,fetch)


def test_changed_route_edition_suspends_mapping(monkeypatch,tmp_path):
    import catalog_inventory,epg_discovery
    root=tmp_path/'channel-catalog';root.mkdir()
    (root/'manifest.json').write_text(json.dumps({'sha256':'fixture-v1'}))
    monkeypatch.setattr(catalog_inventory,'DATA',tmp_path)
    row={'id':'fixture','routes':[{'url':'https://fixture-uk.fast.rakuten.tv/production-LiveChannel-6065/master.m3u8'}]}
    monkeypatch.setattr(epg_discovery,'load_catalog',lambda _:({},[row]))
    context={'marketCode':'uk','serviceId':6065};proof={'providerMarketCode':'uk','providerServiceId':6065}
    r._ROUTE_CACHE.clear();r.verify_current_catalogue_route('fixture',context,proof)
    row['routes'][0]['url']=row['routes'][0]['url'].replace('production-LiveChannel-6065','production-hls-aes128-rtv-6065-playout')
    (root/'manifest.json').write_text(json.dumps({'sha256':'reviewed-current-profile'}))
    r.verify_current_catalogue_route('fixture',context,proof)
    row['routes'].append({'url':'https://fixture-de.fast.rakuten.tv/production-LiveChannel-6066/master.m3u8'})
    (root/'manifest.json').write_text(json.dumps({'sha256':'fixture-v2'}))
    with pytest.raises(EpgError,match='route_edition_requires_review'):r.verify_current_catalogue_route('fixture',context,proof)


def test_delivery_alias_requires_reviewed_host_service_and_market(monkeypatch,tmp_path):
    import catalog_inventory,epg_discovery,broadcast_market
    root=tmp_path/'channel-catalog';root.mkdir()
    (root/'manifest.json').write_text(json.dumps({'sha256':'delivery-fixture'}))
    monkeypatch.setattr(catalog_inventory,'DATA',tmp_path)
    host='b'*32+'.mediatailor.eu-west-1.amazonaws.com'
    url='https://'+host+'/v1/master/'+'a'*40+'/production-LiveChannel-6065/master.m3u8'
    monkeypatch.setattr(epg_discovery,'load_catalog',lambda _:({},[{'id':'fixture','routes':[{'url':url}]}]))
    context={'marketCode':'uk','serviceId':6065};proof={'providerMarketCode':'uk','providerServiceId':6065}
    r._ROUTE_CACHE.clear();monkeypatch.setattr(broadcast_market,'load_matching_bindings',lambda:[])
    with pytest.raises(EpgError,match='route_edition_requires_review'):r.verify_current_catalogue_route('fixture',context,proof)
    binding={'provider':'rakuten-tv','host':host,'serviceId':'6065','market':'GB'}
    monkeypatch.setattr(broadcast_market,'load_matching_bindings',lambda:[binding])
    r.verify_current_catalogue_route('fixture',context,proof)
    binding['market']='DE'
    with pytest.raises(EpgError,match='route_edition_requires_review'):r.verify_current_catalogue_route('fixture',context,proof)


def test_spanish_market_uses_its_classification_service_and_local_calendar():
    source={**SOURCE,'marketCode':'es','calendarTimezone':'Europe/Madrid'}
    value=payload();value['bobtvRequest']['marketCode']='es';value['data'][0]['numerical_id']=6069
    assert r.parse_schedule(json.dumps(value).encode(),source,NOW)['programmes'][0]['originalChannelId']=='rakuten:es:6069'
    def fetch(config):
        from urllib.parse import parse_qs,urlsplit
        query=parse_qs(urlsplit(config['url']).query)
        assert query['classification_id']==['5'] and query['market_code']==['es']
        assert query['epg_starts_at']==['2026-11-14T23:00:00.000Z']
        return json.dumps({'data':value['data'],'meta':{'pagination':{'page':1,'count':1,'total_pages':1}}}).encode(),{}
    body,receipt=r.fetch_schedule(source,NOW,fetch)
    assert receipt['channelsFetched']==1 and receipt['marketCode']=='es'


def test_episode_identity_is_retained_without_fabricating_a_movie():
    value=payload();event=value['data'][0]['live_programs'][0]
    event.update(movie_id=None,episode_id='fixture-show-1-6',season_id='fixture-show-1',subtitle='S1:E6 Fixture')
    record=parse(value)['programmes'][0]
    assert record['movieId'] is None and record['episodeId']=='fixture-show-1-6'
    assert record['seasonId']=='fixture-show-1' and record['episodeLabel']=='S1:E6 Fixture'
