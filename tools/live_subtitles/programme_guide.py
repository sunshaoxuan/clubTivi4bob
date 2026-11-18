"""Resolve a viewer route against the current signed public catalog and EPG.

Client hints never authorize a programme or a media fetch. Only metadata and
subtitle resources are read on the server. Playback timing comes from the client.
"""
import hashlib
import json
import re
import threading
import time
import unicodedata
from urllib.parse import urlsplit, urlencode, quote
from service import snapshot, public_read, official_imdb_id
from subtitle_catalog import title_norm


def identity_title(value):
    return re.findall(r'[^\W_]+',unicodedata.normalize('NFKC',value).casefold())


def route_key(source):
    if not isinstance(source,str):return None
    try:u=urlsplit(source)
    except ValueError:return None
    if not u.scheme or not u.hostname:return None
    # Delivery sessions change while the provider service identity stays fixed.
    if u.scheme=='https' and u.hostname.endswith('-rakuten-tv-uk.fast.rakuten.tv') and not u.username and u.port in (None,443):
        m=re.search(r'/production-(?:LiveChannel-(\d+)|hls-aes128-rtv-(\d+)-playout)/',u.path)
        if m:return (u.hostname,next(x for x in m.groups() if x))
    return source.split('#',1)[0]


class ProgrammeGuide:
    def __init__(self):
        self.lock=threading.RLock();self.metadata={};self.identities={};self.catalog=None;self.catalog_at=0
    def channel(self,source):
        with self.lock:catalog=self.catalog
        if catalog is None:
            catalog=snapshot('channel-catalog')
            with self.lock:self.catalog=catalog;self.catalog_at=time.monotonic()
        key=route_key(source)
        matches=[c for c in catalog['channels'] if key is not None and any(route_key(r['url'])==key for r in c['routes'])]
        if not matches and time.monotonic()-self.catalog_at>25:
            catalog=snapshot('channel-catalog')
            with self.lock:self.catalog=catalog;self.catalog_at=time.monotonic()
            matches=[c for c in catalog['channels'] if key is not None and any(route_key(r['url'])==key for r in c['routes'])]
        if len(matches)!=1:raise ValueError('unbound_public_route')
        return matches[0]
    def current(self,channel_id,source):
        if time.monotonic()-self.catalog_at>25:
            catalog=snapshot('channel-catalog')
            with self.lock:self.catalog=catalog;self.catalog_at=time.monotonic()
        now=time.time();guide=snapshot('epg');rows=[p for p in guide['programmes'] if p['channelId']==channel_id and p['startUtc']<=now<p['stopUtc']]
        if len(rows)!=1:raise ValueError('unambiguous_current_programme_required')
        p=rows[0];facts=p.get('provenance',{});movie=facts.get('movieId');episode=facts.get('episodeId');event=facts.get('sourceEventId')
        key=f"{p['sourceId']}:{p['originalChannelId']}:{event or p['startUtc']}:{p['stopUtc']}:{movie or episode or '-'}"
        result=dict(key=key,catalogChannelId=channel_id,programmeSourceId=p['sourceId'],originalChannelId=p['originalChannelId'],sourceEventId=event,movieId=movie if re.fullmatch(r'[a-z0-9-]{1,200}',movie or '') else None,title=p['title'],year=None,imdbId=None,startUtc=p['startUtc'],stopUtc=p['stopUtc'],clockIsSubtitleOffset=False,searchable=False)
        if p['sourceId'].startswith('rakuten-') and movie and re.fullmatch(r'[a-z0-9-]{1,200}',movie):
            market=facts.get('marketCode');assert re.fullmatch(r'[a-z]{2}',market or '')
            cache_key=(market,movie)
            with self.lock:metadata=self.metadata.get(cache_key)
            if metadata is None:
                metadata=json.loads(public_read('https://gizmo.rakuten.tv/v3/movies/'+movie+'?'+urlencode(dict(classification_id=18,device_identifier='web',locale='en',market_code=market))))['data']
                if metadata['id']!=movie or not isinstance(metadata.get('year'),int):raise ValueError('official_movie_identity_mismatch')
                with self.lock:
                    if len(self.metadata)>=512:self.metadata.pop(next(iter(self.metadata)))
                    self.metadata[cache_key]=metadata
            result.update(title=metadata['title'],year=metadata['year'],imdbId=official_imdb_id(metadata),numericalMovieId=metadata.get('numerical_id'),marketCode=market,serviceId=facts.get('serviceId'),searchable=True,identityEvidence='official_movie_record')
        else:
            # An exact unique movie title can seed retrieval, but cannot authorize
            # captions: every edition still needs independent acoustic alignment.
            title=p['title'];hint=official_imdb_id(facts);year=facts.get('year');identity_key=(title,hint,year)
            with self.lock:cached=self.identities.get(identity_key)
            if cached is None or now-cached[0]>3600:
                rows=json.loads(public_read('https://v3.sg.media-imdb.com/suggestion/x/'+quote(title.lower(),safe='')+'.json')).get('d',[])
                exact=[r for r in rows if r.get('qid')=='movie' and identity_title(title) and identity_title(r.get('l',''))==identity_title(title) and re.fullmatch(r'tt[0-9]{7,10}',r.get('id','')) and isinstance(r.get('y'),int) and (not hint or hint==r['id']) and (not isinstance(year,int) or year==r['y'])]
                found=exact[0] if len({r['id'] for r in exact})==1 else None
                with self.lock:
                    if len(self.identities)>=1024:self.identities.pop(next(iter(self.identities)))
                    self.identities[identity_key]=(now,found)
            else:found=cached[1]
            if found:result.update(year=found['y'],imdbId=found['id'],searchable=True,identityEvidence='exact_unique_title_metadata_pending_audio_verification')
        return source,result
    def resolve(self,source,context=None):
        c=self.channel(source)
        if isinstance(context,dict) and context.get('catalogChannelId') not in (None,c['id']):raise ValueError('route_programme_mismatch')
        return c,self.current(c['id'],source)
