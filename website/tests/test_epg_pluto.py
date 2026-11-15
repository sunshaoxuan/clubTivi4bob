"""Authored Pluto contract fixtures. No live approvals or network calls."""
from datetime import datetime,timezone
import json
from pathlib import Path
import sys
from urllib.parse import urlsplit,parse_qs
sys.path.insert(0,str(Path(__file__).parents[1]))
import pytest
import epg_pluto as p
from epg_ingest import EpgError

NOW=1794784000
SOURCE={'url':p.API,'countryCode':'DE','calendarTimezone':'Europe/Berlin','redirectUrls':[]}
stamp=lambda t:datetime.fromtimestamp(t,timezone.utc).isoformat().replace('+00:00','Z')

def channel(identity):
    return {'_id':identity,'slug':p.CHANNELS[identity],'name':'Fixture '+identity,'number':1,
        'timelines':[{'_id':f'{i+1:024x}','title':'Fixture programme '+str(i),'start':stamp(a),'stop':stamp(b),
            'episode':{'_id':f'{i+10:024x}','description':'excluded rich text'}}
            for i,(a,b) in enumerate([(NOW-100,NOW+100),(NOW+100,NOW+900)])]}

def payload():
    def fetch(url):return json.dumps(channel(urlsplit(url).path.rsplit('/',1)[-1])).encode()
    return p.fetch_schedule(SOURCE,NOW,fetch)[0]

def test_each_exact_channel_is_read_with_explicit_start_stop_and_factual_projection():
    calls=[]
    def fetch(url):
        calls.append(url);return json.dumps(channel(urlsplit(url).path.rsplit('/',1)[-1])).encode()
    body,receipt=p.fetch_schedule(SOURCE,NOW,fetch)
    assert receipt['pagesFetched']==len(calls)==4
    assert all(set(parse_qs(urlsplit(url).query))=={'start','stop'} for url in calls)
    assert b'description' not in body and b'excluded rich text' not in body
    parsed=p.parse_schedule(body,SOURCE,NOW)
    assert parsed['quality']['currentAndFutureChannels']==4
    assert parsed['quality']['acceptedProgrammes']==8
    assert all(r['sourceEventId'] and r['episodeId'] for r in parsed['programmes'])

def test_same_name_from_another_channel_id_never_becomes_reviewed_feed():
    def fetch(url):
        value=channel(urlsplit(url).path.rsplit('/',1)[-1]);value['_id']='f'*24
        return json.dumps(value).encode()
    with pytest.raises(EpgError):p.fetch_schedule(SOURCE,NOW,fetch)

def test_naive_time_and_missing_stop_are_quarantined_without_inference():
    value=json.loads(payload());row=value['data'][0]
    row['timelines'][0]['start']='2026-11-15T22:00:00'
    row['timelines'][1].pop('stop')
    parsed=p.parse_schedule(json.dumps(value).encode(),SOURCE,NOW)
    assert parsed['quality']['rejected']['invalid_programme']==2
    assert parsed['quality']['currentAndFutureChannels']==3

def test_both_conflicting_programmes_are_withheld():
    value=json.loads(payload());row=value['data'][0]
    row['timelines'][1]['start']=stamp(NOW)
    parsed=p.parse_schedule(json.dumps(value).encode(),SOURCE,NOW)
    assert parsed['quality']['rejected']['conflicting_programme']==2
    assert parsed['quality']['currentAndFutureChannels']==3

def test_country_and_source_host_cannot_be_selected_from_route_query_hints():
    identity=next(iter(p.CHANNELS))
    route='https://service-stitcher.clusters.pluto.tv/stitch/hls/channel/'+identity+'/master.m3u8'
    assert p.route_id(route+'?marketingRegion=US')==identity
    assert p.route_id(route.replace('.pluto.tv','.pluto.tv.attacker.example')) is None
    assert p.route_id(route.replace('https://','https://secret@')) is None
    with pytest.raises(EpgError):p.validate_source({**SOURCE,'countryCode':'US'})

def test_all_current_catalogue_routes_must_retain_the_exact_feed(tmp_path,monkeypatch):
    import catalog_inventory,epg_discovery
    identity=next(iter(p.CHANNELS));route='https://service-stitcher.clusters.pluto.tv/stitch/hls/channel/'+identity+'/master.m3u8'
    c={'id':'fixture-channel','countryCode':'DE','routes':[{'url':route}]}
    root=tmp_path/'channel-catalog';root.mkdir();(root/'manifest.json').write_text(json.dumps({'sha256':'a'*64}))
    monkeypatch.setattr(catalog_inventory,'DATA',tmp_path)
    monkeypatch.setattr(epg_discovery,'load_catalog',lambda _:(None,[c]));p._CACHE.clear()
    context={'providerChannelId':identity,'channelSlug':p.CHANNELS[identity]};evidence={'providerChannelId':identity}
    p.verify_current_catalogue_route(c['id'],context,evidence)
    c['routes'].append({'url':route.replace(identity,'f'*24)})
    with pytest.raises(EpgError):p.verify_current_catalogue_route(c['id'],context,evidence)
