"""Unambiguous public JSON schedules with explicit channel identity and times.

Only a selected publisher's channel container is read. Unknown pagination,
rolling date contracts, naive times and duration-derived stops are rejected.
"""
from collections import Counter
from datetime import datetime
import hashlib
import json
import re
from urllib.parse import parse_qsl, urlsplit

from epg_ingest import EpgError, decode
from epg_discovery import canonical

COLLECTIONS = ('schedule', 'schedules', 'programmes', 'programs', 'events', 'epg', 'timelines', 'broadcasts', 'currentSchedule', 'items')
STARTS = ('startUtc', 'starts_at', 'start', 'startTime', 'startDate', 'eventStartMyt')
STOPS = ('stopUtc', 'ends_at', 'stop', 'end', 'endTime', 'endDate', 'eventEndMyt')


def source_id(url, channel, name, country):
    return 'channel-json-'+hashlib.sha256(json.dumps([url, channel, name, country], ensure_ascii=False).encode()).hexdigest()[:24]


def validate_source(source):
    from epg_auto_search import candidate_allowed
    try:
        if (source['id'] != source_id(source['url'], source['catalogChannelId'], source['channelName'], source['countryCode'])
                or not isinstance(source['channelName'], str) or not 1 <= len(source['channelName']) <= 256
                or not re.fullmatch(r'[A-Z]{2}', source['countryCode'])
                or source.get('redirectUrls') or source.get('redirectPolicy')
                or urlsplit(source['url']).scheme != 'https'
                or not candidate_allowed(source['url'], [], 'structured_api')):
            raise ValueError()
        # A static service selector is safe to reuse. Date-dependent request
        # contracts need a reviewed adapter rather than a guessed calendar.
        if any(re.search(r'date|day|start|end|from|to|offset|page', k, re.I)
               for k, _ in parse_qsl(urlsplit(source['url']).query)):
            raise EpgError('publisher_json_rolling_request_adapter_required')
    except (KeyError, TypeError, ValueError) as exc:
        if isinstance(exc, EpgError): raise
        raise EpgError('invalid_publisher_json_contract') from None


def timestamp(value):
    try:
        if type(value) in (int, float):
            stamp = value/1000 if value > 10**12 else value
        elif isinstance(value, str) and re.search(r'(Z|[+-]\d\d:\d\d)$', value):
            stamp = datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
        else:
            raise ValueError()
        if not 0 <= stamp <= 4102444800 or stamp != int(stamp): raise ValueError()
        return int(stamp)
    except (ValueError, OverflowError):
        raise EpgError('publisher_json_explicit_timestamp_required') from None


def walk(root):
    stack, visited = [root], 0
    while stack:
        item = stack.pop(); visited += 1
        if visited > 20000: raise EpgError('publisher_json_record_limit')
        yield item
        if isinstance(item, dict): stack.extend(item.values())
        elif isinstance(item, list): stack.extend(item)


def parse_schedule(payload, source, now):
    validate_source(source)
    try: root = json.loads(decode(payload))
    except (ValueError, UnicodeError): raise EpgError('publisher_json_invalid_response') from None
    containers = []
    for item in walk(root):
        if not isinstance(item, dict) or not any(k in item for k in COLLECTIONS): continue
        names = [item.get(k) for k in ('channelName', 'channel_name', 'serviceName', 'title', 'name')]
        for key in ('channel', 'service'):
            value = item.get(key)
            if isinstance(value, dict): names.extend(value.get(k) for k in ('name', 'title'))
            elif isinstance(value, str): names.append(value)
        if canonical(source['channelName']) in {canonical(n) for n in names if isinstance(n, str)}:
            containers.append(item)
    if len(containers) != 1: raise EpgError('publisher_json_channel_identity_ambiguous')
    container = containers[0]
    if (container.get('hasMore') is True or container.get('next')
            or type(container.get('totalPages')) is int and container['totalPages'] > 1):
        raise EpgError('publisher_json_pagination_adapter_required')
    if container.get('countryCode') and container['countryCode'] != source['countryCode']:
        raise EpgError('publisher_json_country_mismatch')
    original = 'publisher-json:'+source['id'].removeprefix('channel-json-')
    records, rejected = {}, Counter()
    for item in walk({k: container[k] for k in COLLECTIONS if k in container}):
        if not isinstance(item, dict) or not any(k in item for k in STARTS): continue
        try:
            start = timestamp(next(item[k] for k in STARTS if k in item))
            stop = timestamp(next(item[k] for k in STOPS if k in item))
            title = item.get('title', item.get('name'))
            if not isinstance(title, str):
                nested = item.get('programme', item.get('episode', {}))
                title = nested.get('title', nested.get('name')) if isinstance(nested, dict) else None
            if not isinstance(title, str) or not 1 <= len(title.strip()) <= 512 or not 0 < stop-start <= 86400:
                raise ValueError()
            if stop < now-2*86400 or start > now+14*86400: continue
            row = {'originalChannelId': original, 'title': title.strip(), 'startUtc': start, 'endUtc': stop,
                   'endDerived': False, 'sourceUrl': source['url'], 'sourceTimestampEncoding': 'explicit_offset_or_unix'}
            records[(start, stop, title.strip())] = row
        except (ValueError, KeyError, StopIteration): rejected['invalid_programme'] += 1
    ordered = sorted(records.values(), key=lambda p:(p['startUtc'], p['endUtc']))
    conflicts = set()
    for i, event in enumerate(ordered):
        for j in range(i+1, len(ordered)):
            if ordered[j]['startUtc'] >= event['endUtc']: break
            conflicts.update((i,j))
    programmes = [p for i,p in enumerate(ordered) if i not in conflicts]
    rejected['overlapping_programme'] += len(conflicts)
    current = any(p['startUtc'] <= now < p['endUtc'] for p in programmes)
    future = any(p['startUtc'] > now for p in programmes)
    return {'channels': {original: [source['channelName']]},
        'identityContexts': {original: {'provider':'publisher-json', 'countryCode':source['countryCode'],
            'catalogChannelId':source['catalogChannelId'], 'publisherChannelName':source['channelName']}},
        'programmes': programmes, 'quality': {'declaredChannels':1, 'usableChannels':1,
            'acceptedProgrammes':len(programmes), 'currentChannels':int(current), 'futureChannels':int(future),
            'currentAndFutureChannels':int(current and future), 'rejected':dict(rejected),
            'coverageStartUtc':min((p['startUtc'] for p in programmes), default=None),
            'coverageEndUtc':max((p['endUtc'] for p in programmes), default=None)}}


def success_refresh_delay(parsed, now, requested):
    remaining = (parsed['quality']['coverageEndUtc'] or now)-now
    margin = max(300, min(6*3600, remaining//4))
    return max(60, min(requested, remaining-margin))
