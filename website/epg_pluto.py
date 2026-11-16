"""Exact Pluto channel IDs with explicit UTC programme windows.

The generic channel listing may be empty while channel detail contains a full
schedule when start/stop are supplied. Reviewed German, British and Spanish feed IDs have separate source scopes.
Names and route query hints cannot approve a mapping.
"""
from collections import Counter
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import hashlib
import json
from pathlib import Path
import re
import urllib.error
import urllib.request
from urllib.parse import urlencode, urlsplit

API = 'https://api.pluto.tv/v2/channels'
CHANNELS = {
    '5c5c3b948002db3c3e0b262e': 'pluto-tv-movies-de',
    '5d767b1c126c65d0a307355f': 'pluto-tv-history-de-1',
    '5caf325764025859afdd6c4d': 'mtv-pluto-tv-de',
    '5db6a697d5f34a000934cd13': 'mtv-catfish-tv-show-de',
}


SCOPES = {
    'pluto-de-official-v1': ('DE', 'Europe/Berlin', CHANNELS),
    'pluto-de-comedy-official-v1': ('DE', 'Europe/Berlin', {'5d4947590ba40f75dc29c26b': 'comedy-central-pluto-tv-de'}),
    'pluto-gb-official-v1': ('GB', 'Europe/London', {'5cb6f6f9a461406ffe4022cf': 'the-fbi-files-gb'}),
    'pluto-es-official-v1': ('ES', 'Europe/Madrid', {'5f1aca8310a30e00074fab92': 'los-asesinatos-de-midsomer-es'}),
}
ALL_CHANNELS = {identity:(country,slug) for country,_,channels in SCOPES.values() for identity,slug in channels.items()}


def scope(source):
    from epg_ingest import EpgError
    value=SCOPES.get(source.get('id','pluto-de-official-v1'))
    if value is None:raise EpgError('unreviewed_pluto_source_scope')
    return value


def validate_source(source):
    from epg_ingest import EpgError
    country,zone,_=scope(source)
    if (source.get('url') != API or source.get('countryCode') != country
            or source.get('calendarTimezone') != zone
            or source.get('redirectUrls') or source.get('redirectPolicy')):
        raise EpgError('invalid_pluto_source_contract')


def route_id(url):
    try:
        p = urlsplit(url)
        if (p.scheme != 'https' or p.hostname != 'service-stitcher.clusters.pluto.tv'
                or p.username or p.password or p.fragment or p.port not in (None,443)):
            return None
        match = re.fullmatch(r'/(?:v1/)?stitch/(?:embed/)?hls/channel/([a-f0-9]{24})/master\.m3u8',p.path)
        return match[1] if match else None
    except (ValueError,TypeError):
        return None


def fetch_schedule(source, now, fetcher=None):
    from epg_ingest import EpgError, NoRedirect
    from process_channel_inventory import _HTTPSHandler
    from source_registry import validate_public_url
    validate_source(source);validate_public_url(API)
    if fetcher is None:
        def fetcher(url):
            opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect(),_HTTPSHandler())
            try:
                response=opener.open(urllib.request.Request(url,headers={'User-Agent':'BobTV-EPG-Validator/1.0','Accept-Encoding':'identity'}),timeout=8)
            except urllib.error.HTTPError as error:
                value=error.headers.get('Retry-After','0').strip()
                try:retry=int(value) if value.isdecimal() else max(0,int(parsedate_to_datetime(value).timestamp()-now))
                except (ValueError,TypeError,OverflowError):retry=0
                raise EpgError('http_'+str(error.code),retry) from None
            with response:
                if response.status!=200 or response.geturl()!=url:raise EpgError('pluto_unreviewed_response')
                raw=response.read(2*1024*1024+1)
            if len(raw)>2*1024*1024:raise EpgError('pluto_response_limit')
            return raw
    stamp=lambda seconds:datetime.fromtimestamp(seconds,timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z')
    start=now//3600*3600-3600;stop=now//3600*3600+13*3600
    country,_,channels=scope(source)
    records=[];receipts=[]
    for identity,slug in channels.items():
        url=API+'/'+identity+'?'+urlencode({'start':stamp(start),'stop':stamp(stop)})
        raw=fetcher(url)
        try:
            data=json.loads(raw)
            if data['_id']!=identity or data['slug']!=slug:raise EpgError('pluto_feed_identity_mismatch')
            timelines=data['timelines']
            if not isinstance(timelines,list) or len(timelines)>500:raise EpgError('pluto_timeline_limit')
            projected={k:data[k] for k in ['_id','slug','name','number']}
            projected['timelines']=[{**{k:e.get(k) for k in ['_id','title','start','stop']},
                'episodeId':e.get('episode',{}).get('_id')} for e in timelines]
            records.append(projected)
        except (ValueError,KeyError,TypeError):raise EpgError('pluto_invalid_json_contract') from None
        receipts.append({'url':url,'sha256':hashlib.sha256(raw).hexdigest()})
    payload=json.dumps({'market':country,'data':records},ensure_ascii=False).encode()
    return payload,{'sourceUrl':API,'fetchedAtUtc':now,'pagesFetched':len(receipts),'requestReceipts':receipts,
                    'windowStart':stamp(start),'windowEnd':stamp(stop)}


def parse_schedule(payload,source,now):
    from epg_ingest import EpgError
    validate_source(source);country,_,selected=scope(source)
    try:
        value=json.loads(payload)
        if value['market']!=country or {r['_id'] for r in value['data']}!=set(selected) or len(value['data'])!=len(selected):raise ValueError()
    except (ValueError,TypeError,KeyError):raise EpgError('pluto_market_identity_mismatch') from None
    channels={};contexts={};programmes=[];rejected=Counter()
    def stamp(text):
        if not isinstance(text,str):raise ValueError()
        dt=datetime.fromisoformat(text.replace('Z','+00:00'))
        if dt.tzinfo is None:raise ValueError()
        return int(dt.timestamp())
    for row in value['data']:
        identity=row['_id'];original='pluto:'+country.lower()+':'+identity
        if row.get('slug')!=selected[identity] or not isinstance(row.get('name'),str) or not 0<len(row['name'])<=512:
            raise EpgError('pluto_feed_identity_mismatch')
        channels[original]=[row['name']]
        contexts[original]={'provider':'pluto-tv','providerChannelId':identity,'channelSlug':row['slug'],
            'countryCode':country,'regionCode':None,'sourceTimestampEncoding':'iso8601_explicit_offset'}
        unique={};conflicts=set()
        for e in row['timelines']:
            try:
                start,end=stamp(e['start']),stamp(e['stop']);event=e['_id'];title=e['title'];episode=e.get('episodeId')
                if (not re.fullmatch(r'[a-f0-9]{24}',event) or not isinstance(title,str) or not 0<len(title.strip())<=512
                        or not 0<end-start<=86400 or start>now+14*86400 or end<now-2*86400
                        or (episode is not None and not re.fullmatch(r'[a-f0-9]{24}',episode))):raise ValueError()
                record={'originalChannelId':original,'title':title.strip(),'startUtc':start,'endUtc':end,
                    'sourceEventId':event,'episodeId':episode,'providerChannelId':identity,'channelSlug':row['slug'],
                    'sourceEndUtc':end,'endDerived':False,'sourceTimestampEncoding':'iso8601_explicit_offset','sourceUrl':API}
                if event in unique and unique[event]!=record:conflicts.add(event)
                else:unique[event]=record
            except (ValueError,TypeError,KeyError):rejected['invalid_programme']+=1
        ordered=sorted(unique.values(),key=lambda r:(r['startUtc'],r['endUtc']))
        for index,a in enumerate(ordered):
            for b in ordered[index+1:]:
                if b['startUtc']>=a['endUtc']:break
                conflicts.update([a['sourceEventId'],b['sourceEventId']])
        rejected['conflicting_programme']+=len(conflicts)
        programmes.extend(r for r in ordered if r['sourceEventId'] not in conflicts)
    current={p['originalChannelId'] for p in programmes if p['startUtc']<=now<p['endUtc']}
    future={p['originalChannelId'] for p in programmes if p['startUtc']>now}
    return {'channels':channels,'identityContexts':contexts,'programmes':programmes,
        'quality':{'declaredChannels':len(channels),'usableChannels':len(channels),'acceptedProgrammes':len(programmes),
            'currentChannels':len(current),'futureChannels':len(future),'currentAndFutureChannels':len(current&future),
            'coverageStartUtc':min((p['startUtc'] for p in programmes),default=None),
            'coverageEndUtc':max((p['endUtc'] for p in programmes),default=None),'rejected':dict(rejected)}}


_CACHE={}
def verify_current_catalogue_route(channel_id,context,evidence):
    from catalog_inventory import DATA
    from epg_discovery import load_catalog
    from epg_ingest import EpgError
    try:
        digest=json.loads((Path(DATA)/'channel-catalog/manifest.json').read_text())['sha256'];key=(str(DATA),digest)
        if key not in _CACHE:
            _,rows=load_catalog(DATA);_CACHE.clear();_CACHE[key]={c['id']:c for c in rows}
        channel=_CACHE[key][channel_id];identity=context['providerChannelId']
        expected_country,expected_slug=ALL_CHANNELS[identity]
        if (channel['countryCode']!=expected_country or context['countryCode']!=expected_country or context['channelSlug']!=expected_slug
                or evidence.get('providerChannelId')!=identity or not channel['routes']
                or any(route_id(r['url'])!=identity for r in channel['routes'])):raise ValueError()
    except (OSError,ValueError,TypeError,KeyError):raise EpgError('pluto_current_route_edition_requires_review') from None
