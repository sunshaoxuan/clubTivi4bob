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
from pathlib import Path
from urllib.parse import urlsplit, urlencode, quote
from urllib.request import Request, urlopen
from service import snapshot, public_read, official_imdb_id
from subtitle_catalog import title_norm


def wikidata_read(**query):
    url = 'https://www.wikidata.org/w/api.php?' + urlencode(dict(format='json', **query))
    with urlopen(Request(url, headers={'User-Agent': 'BobTV-Subtitle/1.0'}), timeout=5) as response:
        if urlsplit(response.url).hostname != 'www.wikidata.org':
            raise ValueError('unreviewed_film_identity_redirect')
        raw = response.read(1024 * 1024 + 1)
    if len(raw) > 1024 * 1024:
        raise ValueError('film_identity_response_limit')
    return json.loads(raw)


def film_number(title):
    # Normalize Unicode Roman sequel numbers without dropping the sequel.
    return re.sub(r'[\u2160-\u216b\u2170-\u217b]$',
                  lambda match: str(int(unicodedata.numeric(match[0]))), title)


def film_search_title(title):
    # A programme may split one feature across two broadcast slots. Strip only
    # explicit bracketed part markers, retaining numbered sequel identities.
    return film_number(re.sub(r'\s*[（(](?:上|中|下)(?:集|部)?[）)]\s*$', '', title).strip())


def film_alias(title, year=None, imdb_id=None):
    """Require a unique film with the exact localized label or alias."""
    title = film_search_title(title)
    # Reviewed localized titles bridge gaps in Wikidata. A checked-in pointer
    # still needs a fresh matching movie record before seeding subtitle search.
    aliases = json.loads((Path(__file__).with_name('film_identity_aliases.json')).read_text())
    if aliases.get('schemaVersion') != 1 or len(aliases.get('films', [])) > 256:
        raise ValueError('invalid_reviewed_film_aliases')
    reviewed = [film for film in aliases['films']
                if any(identity_title(name) == identity_title(title) for name in film['titles'])]
    if reviewed:
        if len(reviewed) != 1:
            return None
        film = reviewed[0]
        imdb, released = film['imdbId'], film['year']
        if (not re.fullmatch(r'tt[0-9]{7,10}', imdb) or type(released) is not int
                or (year is not None and year != released) or (imdb_id and imdb_id != imdb)):
            return None
        rows = json.loads(public_read('https://v3.sg.media-imdb.com/suggestion/x/'+imdb+'.json')).get('d', [])
        matching = [r for r in rows if r.get('id') == imdb and r.get('qid') == 'movie'
                    and r.get('y') == released and identity_title(r.get('l','')) == identity_title(film['imdbTitle'])]
        if len(matching) != 1:
            return None
        return dict(title=matching[0]['l'], year=released, imdbId=imdb,
                    verifiedTitleAliases=film.get('releaseTitles', []),
                    identityEvidence='reviewed_localized_title_pending_audio_verification')
    language = 'zh' if re.search(r'[\u3400-\u9fff]', title) else 'en'
    results = wikidata_read(action='wbsearchentities', language=language, search=title, limit=6)
    ids = [r['id'] for r in results.get('search', []) if re.fullmatch(r'Q[0-9]+', r.get('id', ''))][:6]
    if not ids:
        return None
    entities = wikidata_read(action='wbgetentities', ids='|'.join(ids),
                             props='labels|aliases|claims', languages='zh|zh-hans|zh-hant|en')
    matches = {}
    for item in entities.get('entities', {}).values():
        claims = item.get('claims', {})
        def values(prop):
            return [r.get('mainsnak', {}).get('datavalue', {}).get('value')
                    for r in claims.get(prop, []) if r.get('rank') != 'deprecated']
        if not any(isinstance(v, dict) and v.get('id') == 'Q11424' for v in values('P31')):
            continue
        labels = item.get('labels', {})
        names = list(labels.values()) + [a for entries in item.get('aliases', {}).values() for a in entries]
        if not any(identity_title(n.get('value', '')) == identity_title(title) for n in names):
            continue
        imdb_ids = {v for v in values('P345') if isinstance(v, str) and re.fullmatch(r'tt[0-9]{7,10}', v)}
        years = {int(v['time'][1:5]) for v in values('P577') if isinstance(v, dict)
                 and re.match(r'^\+[0-9]{4}-', v.get('time', ''))}
        if len(imdb_ids) != 1 or len(years) != 1:
            continue
        imdb, released = next(iter(imdb_ids)), next(iter(years))
        if (year is not None and released != year) or (imdb_id and imdb_id != imdb):
            continue
        matches[imdb] = dict(title=labels.get('en', {}).get('value') or title,
                             imdbId=imdb, year=released)
    return next(iter(matches.values())) if len(matches) == 1 else None


def is_player_epg(context):
    return isinstance(context, dict) and context.get('contextKind') == 'player-epg-v1'


def player_programme(context, channel_id, now):
    title, start, stop = (context.get(k) for k in ('title', 'startUtc', 'stopUtc'))
    if (context.get('catalogChannelId') != channel_id or not isinstance(title, str)
            or not 0 < len(title) <= 200 or title != title.strip()
            or not identity_title(title) or any(ord(c) < 32 for c in title)
            or type(start) is not int or type(stop) is not int
            or not start <= now < stop or stop - start > 8 * 3600):
        raise ValueError('invalid_player_programme')
    material = json.dumps([channel_id, title, start, stop], ensure_ascii=False, separators=(',', ':'))
    key = 'player-epg:' + hashlib.sha256(material.encode()).hexdigest()
    if context.get('key') != key:
        raise ValueError('invalid_player_programme_key')
    return dict(key=key, catalogChannelId=channel_id, title=title, startUtc=start, stopUtc=stop,
                contextKind='player-epg-v1', year=None, imdbId=None, movieId=None,
                clockIsSubtitleOffset=False)


def identity_title(value):
    return re.findall(r'[^\W_]+',unicodedata.normalize('NFKC',film_number(value)).casefold())


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
        self.lock=threading.RLock();self.metadata={};self.identities={};self.catalog=None;self.catalog_at=0;self.indexed_catalog=None;self.route_index={}
        self.player_lookup_attempts = []
        self.player_lookup_slots = threading.BoundedSemaphore(2)
    def indexed_channels(self,catalog,key):
        with self.lock:
            if self.indexed_catalog is not catalog:
                index={}
                for channel in catalog['channels']:
                    keys={route_key(route['url']) for route in channel['routes']}
                    for route in keys:
                        if route is not None:index.setdefault(route,[]).append(channel)
                self.route_index=index;self.indexed_catalog=catalog
            return self.route_index.get(key,[]) if key is not None else []

    def player_search_identity(self, programme):
        title = programme['title']
        key = ('player-alias', title)
        now = time.time()
        with self.lock:
            cached = self.identities.get(key)
        if cached and now - cached[0] <= 3600:
            result = cached[1]
        else:
            if not self.player_lookup_slots.acquire(blocking=False):
                raise RuntimeError('player_film_lookup_busy')
            try:
                with self.lock:
                    self.player_lookup_attempts = [t for t in self.player_lookup_attempts if now-t < 60]
                    if len(self.player_lookup_attempts) >= 24:
                        raise RuntimeError('player_film_lookup_budget')
                    self.player_lookup_attempts.append(now)
                result = film_alias(title)
                with self.lock:
                    if len(self.identities) >= 1024:self.identities.pop(next(iter(self.identities)))
                    self.identities[key] = (now, result)
            finally:
                self.player_lookup_slots.release()
        return {**programme, **result, 'searchable': True} if result else None

    def channel(self,source):
        with self.lock:catalog=self.catalog
        if catalog is None:
            catalog=snapshot('channel-catalog')
            with self.lock:self.catalog=catalog;self.catalog_at=time.monotonic()
        key=route_key(source)
        matches=self.indexed_channels(catalog,key)
        if not matches and time.monotonic()-self.catalog_at>25:
            catalog=snapshot('channel-catalog')
            with self.lock:self.catalog=catalog;self.catalog_at=time.monotonic()
            matches=self.indexed_channels(catalog,key)
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
            elif re.search(r'[\u3400-\u9fff]', title) and (not cached or now-cached[0]>3600) and not exact:
                try:
                    alias=film_alias(title,year if type(year) is int else None,hint)
                except (OSError, ValueError, TypeError, KeyError):
                    alias=None
                if alias:
                    with self.lock:self.identities[identity_key]=(now,dict(y=alias['year'],id=alias['imdbId'],l=alias['title']))
                    result.update(**alias,searchable=True,identityEvidence='localized_film_alias_pending_audio_verification')
            if found and found.get('l') and identity_title(found['l']) != identity_title(title):
                result.update(title=found['l'],identityEvidence='localized_film_alias_pending_audio_verification')
        return source,result
    def resolve(self,source,context=None):
        c=self.channel(source)
        if isinstance(context,dict) and context.get('catalogChannelId') not in (None,c['id']):raise ValueError('route_programme_mismatch')
        if is_player_epg(context):
            return c,(source,player_programme(context,c['id'],time.time()))
        return c,self.current(c['id'],source)
