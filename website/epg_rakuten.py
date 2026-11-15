"""Official Rakuten EPG contract: market-scoped pagination and factual records.

Provider identities are discovery candidates. Exact route mappings are reviewed
separately. Film descriptions, plots and artwork are never published by this adapter.
"""
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
import hashlib
import json
import re
import time
from pathlib import Path
from urllib.parse import urlencode, urlsplit
import urllib.request
import urllib.error
from email.utils import parsedate_to_datetime
from zoneinfo import ZoneInfo

from epg_ingest import EpgError, decode, NoRedirect
from process_channel_inventory import _HTTPSHandler
from source_registry import validate_public_url

API = 'https://gizmo.rakuten.tv/v3/live_channels'
ANCHORS = {'uk': ('action-rakuten-tv', 6065), 'de': ('action-rakuten-tv', 6066), 'es': ('action-rakuten-tv',6069)}
ZONES = {'uk': 'Europe/London', 'de': 'Europe/Berlin','es':'Europe/Madrid'}
CLASSIFICATIONS = {'uk':18,'de':307,'es':5}


def validate_source(source):
    market = source.get('marketCode')
    if (source.get('url') != API or market not in ANCHORS
            or source.get('calendarTimezone') != ZONES[market]
            or source.get('redirectUrls') or source.get('redirectPolicy')):
        raise EpgError('invalid_rakuten_source_contract')


def window(source, now):
    validate_source(source)
    zone = ZoneInfo(source['calendarTimezone'])
    local = datetime.fromtimestamp(now, zone)
    start = local.replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + timedelta(days=2)
    return tuple(value.astimezone(timezone.utc).isoformat(timespec='milliseconds')
                 .replace('+00:00', 'Z') for value in (start, end))


def fetch_page(source):
    # Only the fixed reviewed host/path is validated; generated scalar query
    # parameters do not pass through the generic arbitrary-source URL boundary.
    validate_public_url(API)
    url = source['url']
    if not url.startswith(API+'?'):
        raise EpgError('rakuten_unreviewed_request_url')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(), _HTTPSHandler())
    started = time.monotonic()
    try:
        response = opener.open(urllib.request.Request(url, headers={
            'User-Agent': 'BobTV-EPG-Validator/1.0', 'Accept-Encoding': 'identity'}), timeout=8)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        if response.code != 200 or response.geturl() != url:
            value = response.headers.get('Retry-After', '')
            try:
                retry = int(value) if value.isdecimal() else max(0, int(parsedate_to_datetime(value).timestamp()-time.time()))
            except (ValueError, TypeError, OverflowError):
                retry = 0
            raise EpgError('http_'+str(response.code), retry)
        chunks, size = [], 0
        while True:
            if time.monotonic()-started > 32:
                raise EpgError('fetch_deadline')
            chunk = response.read(65536)
            if not chunk:
                break
            size += len(chunk)
            if size > 8*1024*1024:
                raise EpgError('compressed_size_limit')
            chunks.append(chunk)
        return b''.join(chunks), {'sourceUrl': url, 'fetchedAtUtc': int(time.time()), 'serverDate': response.headers.get('Date')}


def fetch_schedule(source, now, fetcher=fetch_page):
    start, end = window(source, now)
    market = source['marketCode']
    channels, receipts, seen = [], [], set()
    page, expected_count, total_pages = 1, None, None
    while total_pages is None or page <= total_pages:
        if page > 20:
            raise EpgError('rakuten_pagination_limit')
        params = dict(classification_id=CLASSIFICATIONS[market], device_identifier='web', locale='en',
            market_code=market, per_page=25, page=page,
            epg_starts_at=start, epg_ends_at=end)
        url = API + '?' + urlencode(params)
        body, receipt = fetcher({**source, 'url': url, 'redirectUrls': []})
        try:
            value = json.loads(decode(body))
            rows = value['data']
            pagination = value['meta']['pagination']
            count, pages = pagination['count'], pagination['total_pages']
            if (not isinstance(rows, list) or not rows or pagination['page'] != page
                    or type(count) is not int or not 1 <= count <= 2000
                    or type(pages) is not int or not 1 <= pages <= 20
                    or expected_count is not None and (count != expected_count or pages != total_pages)):
                raise ValueError()
            expected_count, total_pages = count, pages
            for row in rows:
                identity = row['numerical_id']
                if type(identity) is not int or identity <= 0 or identity in seen:
                    raise ValueError()
                seen.add(identity)
                # Cache only factual metadata, retaining a hash of each original response.
                projected = {key: row[key] for key in ('id','numerical_id','title','content_aggregator_id') if key in row}
                if 'live_programs' in row:
                    projected['live_programs'] = [{key: event[key] for key in
                        ('id','title','starts_at','ends_at','movie_id','episode_id','season_id','subtitle','is_live') if key in event}
                        for event in row['live_programs']]
                channels.append(projected)
        except (ValueError, KeyError, TypeError):
            raise EpgError('rakuten_incomplete_or_ambiguous_pagination') from None
        receipts.append({'url': url, 'sha256': hashlib.sha256(body).hexdigest(),
                         'fetchedAtUtc': receipt.get('fetchedAtUtc', now), 'serverDate': receipt.get('serverDate')})
        page += 1
    if len(channels) != expected_count:
        raise EpgError('rakuten_incomplete_pagination')
    anchor = ANCHORS[market]
    if not any(row.get('id') == anchor[0] and row['numerical_id'] == anchor[1] for row in channels):
        raise EpgError('rakuten_market_identity_mismatch')
    payload = json.dumps({'data': channels, 'bobtvRequest': {'marketCode': market,
        'startsAt': start, 'endsAt': end, 'pages': receipts,'projectionVersion':2}}, ensure_ascii=False).encode()
    if len(payload) > 8 * 1024 * 1024:
        raise EpgError('rakuten_payload_limit')
    return payload, {'sourceUrl': API, 'marketCode': market, 'windowStart': start,
        'windowEnd': end, 'pagesFetched': total_pages, 'channelsFetched': len(channels),
        'fetchedAtUtc': now, 'requestReceipts': receipts,'projectionVersion':2}


def timestamp(value):
    if not isinstance(value, str) or not re.search(r'(Z|[+-]\d\d:\d\d)$', value):
        raise EpgError('rakuten_timestamp_requires_offset')
    try:
        result = datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
        if not 0 <= result <= 4102444800 or result != int(result):
            raise ValueError()
        return int(result)
    except (ValueError, OverflowError):
        raise EpgError('rakuten_invalid_timestamp') from None


def parse_schedule(payload, source, now):
    validate_source(source)
    try:
        value = json.loads(decode(payload))
        rows = value['data']
        if (value['bobtvRequest']['marketCode'] != source['marketCode']
                or not isinstance(rows, list) or not 1 <= len(rows) <= 2000):
            raise ValueError()
    except (ValueError, TypeError, KeyError):
        raise EpgError('rakuten_invalid_response_context') from None
    market = source['marketCode']
    anchor_slug, anchor_id = ANCHORS[market]
    if not any(row.get('id') == anchor_slug and row.get('numerical_id') == anchor_id for row in rows):
        raise EpgError('rakuten_market_identity_mismatch')
    channels, contexts, programmes, seen, rejected = {}, {}, [], set(), Counter()
    for row in rows:
        service, slug, name = row.get('numerical_id'), row.get('id'), row.get('title')
        if (type(service) is not int or service <= 0 or service in seen
                or not isinstance(slug, str) or not re.fullmatch(r'[a-z0-9-]{1,160}', slug)
                or not isinstance(name, str) or not 1 <= len(name.strip()) <= 256):
            raise EpgError('rakuten_ambiguous_channel_identity')
        seen.add(service)
        original_id = f'rakuten:{market}:{service}'
        channels[original_id] = [name.strip()]
        contexts[original_id] = {'provider': 'rakuten-tv', 'marketCode': market, 'serviceId': service,
            'channelSlug': slug, 'sourceTimezone': source['calendarTimezone'],
            'sourceCalendarTimezoneVerified': True, 'contextVerifiedForCatalog': False}
        if 'live_programs' not in row or not isinstance(row['live_programs'], list):
            rejected['schedule_field_absent'] += 1
            continue
        candidates, conflicts = {}, set()
        for event in row['live_programs']:
            try:
                start, end = timestamp(event['starts_at']), timestamp(event['ends_at'])
                title, event_id = event['title'], str(event['id'])
                if (not isinstance(title, str) or not 1 <= len(title.strip()) <= 512
                        or not re.fullmatch(r'[0-9]{1,30}', event_id)
                        or not 0 < end-start <= 86400):
                    raise EpgError('rakuten_invalid_programme')
                movie = event.get('movie_id')
                if movie is not None and (not isinstance(movie, str)
                        or not re.fullmatch(r'[a-z0-9-]{1,200}', movie)):
                    raise EpgError('rakuten_invalid_movie_id')
                episode, season = event.get('episode_id'), event.get('season_id')
                for identity in (episode,season):
                    if identity is not None and (not isinstance(identity,str)
                            or not re.fullmatch(r'[a-z0-9-]{1,200}',identity)):
                        raise EpgError('rakuten_invalid_episode_id')
                label=event.get('subtitle')
                if label is not None and (not isinstance(label,str) or len(label)>512):
                    raise EpgError('rakuten_invalid_episode_label')
                programme = {'originalChannelId': original_id, 'title': title.strip(),
                    'startUtc': start, 'endUtc': end, 'endDerived': False,
                    'sourceEventId': event_id, 'movieId': movie,
                    'episodeId':episode,'seasonId':season,'episodeLabel':label,
                    'sourceIsLive': event.get('is_live'), 'marketCode': market,
                    'serviceId': service, 'channelSlug': slug,
                    'sourceTimestampEncoding': 'iso8601_explicit_offset',
                    'sourceEndUtc': end, 'sourceUrl': source['url']}
                if event_id in candidates and candidates[event_id] != programme:
                    conflicts.add(event_id)
                candidates[event_id] = programme
            except (EpgError, KeyError, TypeError, ValueError):
                rejected['invalid_programme'] += 1
        ordered = sorted((p for key, p in candidates.items() if key not in conflicts),
                         key=lambda p: (p['startUtc'], p['sourceEventId']))
        rejected['conflicting_event_id'] += len(conflicts)
        # Quarantine every member of an overlap, not merely the later record.
        ambiguous = set()
        for index, event in enumerate(ordered):
            for following in ordered[index+1:]:
                if following['startUtc'] >= event['endUtc']:
                    break
                ambiguous.update((event['sourceEventId'], following['sourceEventId']))
        for event in ordered:
            if event['sourceEventId'] in ambiguous:
                rejected['overlapping_programme'] += 1
            elif event['endUtc'] >= now-2*86400 and event['startUtc'] <= now+14*86400:
                programmes.append(event)
    current = {p['originalChannelId'] for p in programmes if p['startUtc'] <= now < p['endUtc']}
    future = {p['originalChannelId'] for p in programmes if p['startUtc'] > now}
    return {'channels': channels, 'identityContexts': contexts, 'programmes': programmes,
        'quality': {'declaredChannels': len(channels), 'usableChannels': len(channels),
            'acceptedProgrammes': len(programmes), 'currentChannels': len(current),
            'futureChannels': len(future), 'currentAndFutureChannels': len(current & future),
            'coverageStartUtc': min((p['startUtc'] for p in programmes), default=None),
            'coverageEndUtc': max((p['endUtc'] for p in programmes), default=None),
            'rejected': dict(rejected)}}


_ROUTE_CACHE = {}

def verify_current_catalogue_route(channel_id, context, evidence):
    """Recheck live route editions without changing the client identity hash."""
    from catalog_inventory import DATA
    from epg_discovery import load_catalog
    manifest_path = Path(DATA)/'channel-catalog/manifest.json'
    try:
        manifest = json.loads(manifest_path.read_text())
        digest = manifest['sha256']
        key = (str(DATA), digest)
        if key not in _ROUTE_CACHE:
            _, channels = load_catalog(DATA)
            _ROUTE_CACHE.clear()
            _ROUTE_CACHE[key] = {row['id']: row for row in channels}
        channel = _ROUTE_CACHE[key].get(channel_id)
        if (channel is None or evidence.get('providerMarketCode') != context['marketCode']
                or evidence.get('providerServiceId') != context['serviceId']):
            raise ValueError()
        routes = channel.get('routes', [])
        if not routes:
            raise ValueError()
        for route in routes:
            uri = urlsplit(route['url'].split('|', 1)[0])
            match = re.search(r'/production-LiveChannel-(\d+)/', uri.path)
            if (uri.scheme != 'https' or not uri.hostname
                    or not match or int(match[1]) != context['serviceId']):
                raise ValueError()
            if not uri.hostname.endswith('-'+context['marketCode']+'.fast.rakuten.tv'):
                # Explicit delivery aliases only, reviewed against the same
                # programme and media asset on the provider-owned route.
                from broadcast_market import provider_service, load_matching_bindings
                key = provider_service(route['url'])
                expected_market = {'uk':'GB','de':'DE'}[context['marketCode']]
                bindings = [b for b in load_matching_bindings()
                    if (b['provider'],b['host'],str(b['serviceId'])) == key]
                if (not key or key[2] != str(context['serviceId']) or not bindings
                        or {b['market'] for b in bindings} != {expected_market}):
                    raise ValueError()
    except (OSError, ValueError, TypeError, KeyError):
        raise EpgError('rakuten_current_route_edition_requires_review') from None
