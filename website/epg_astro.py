"""Astro Malaysia's public service schedules, projected to factual EPG fields.

One provider contract serves all selected services. Catalogue routes and feed
editions still require separate review; provider names never approve a route.
"""
from collections import Counter
from datetime import datetime
import hashlib
import json
import re

from epg_ingest import EpgError, decode, fetch

API = 'https://contenthub-api.eco.astro.com.my'
DIRECTORY = API + '/channel/all.json'


def validate_source(source):
    ids = source.get('serviceIds')
    if (source.get('url') != DIRECTORY or source.get('countryCode') != 'MY'
            or source.get('calendarTimezone') != 'Asia/Kuala_Lumpur'
            or source.get('redirectUrls') or source.get('redirectPolicy')
            or not isinstance(ids, list) or not 1 <= len(ids) <= 10
            or any(type(s) is not int or not 1 <= s <= 10000 for s in ids)
            or ids != sorted(set(ids))):
        raise EpgError('invalid_astro_source_contract')


def fetch_schedule(source, now, fetcher=fetch):
    validate_source(source)
    services, receipts = [], []
    for service_id in source['serviceIds']:
        url = API + '/channel/' + str(service_id) + '.json'
        body, receipt = fetcher({'url': url, 'redirectUrls': []})
        try:
            root = json.loads(decode(body))
            row = root['response']
            schedule = row['schedule']
            if (root.get('responseCode') not in (200, '200') or row['id'] != service_id
                    or not isinstance(schedule, dict) or not 1 <= len(schedule) <= 14
                    or any(not re.fullmatch(r'\d{4}-\d{2}-\d{2}', k)
                           or not isinstance(v, list) or len(v) > 500 for k, v in schedule.items())):
                raise ValueError()
            # No descriptions, artwork, cast lists or unrelated operator data.
            projected = {k: row[k] for k in ('id', 'title', 'stbNumber')}
            projected['schedule'] = [{k: event[k] for k in
                ('title', 'eventStartMyt', 'eventEndMyt', 'siTrafficKey', 'programKey') if k in event}
                for events in schedule.values() for event in events]
            services.append(projected)
        except (ValueError, KeyError, TypeError):
            raise EpgError('astro_incomplete_service_response') from None
        receipts.append({'url': url, 'sha256': hashlib.sha256(body).hexdigest(),
                         'fetchedAtUtc': now, 'serverDate': receipt.get('serverDate')})
    payload = json.dumps({'provider': 'astro-malaysia', 'serviceIds': source['serviceIds'],
                         'services': services}, ensure_ascii=False).encode()
    if len(payload) > 8 * 1024 * 1024:
        raise EpgError('astro_payload_limit')
    return payload, {'sourceUrl': DIRECTORY, 'fetchedAtUtc': now,
                     'pagesFetched': len(receipts), 'requestReceipts': receipts}


def timestamp(value):
    if not isinstance(value, str) or not value.endswith('+08:00'):
        raise EpgError('astro_timestamp_requires_malaysia_offset')
    try:
        result = datetime.fromisoformat(value).timestamp()
        if not 0 <= result <= 4102444800 or result != int(result):
            raise ValueError()
        return int(result)
    except (ValueError, OverflowError):
        raise EpgError('astro_invalid_timestamp') from None


def parse_schedule(payload, source, now):
    validate_source(source)
    try:
        value = json.loads(decode(payload))
        rows = value['services']
        if (value.get('provider') != 'astro-malaysia' or value.get('serviceIds') != source['serviceIds']
                or not isinstance(rows, list) or len(rows) != len(source['serviceIds'])
                or sorted(r['id'] for r in rows) != source['serviceIds']):
            raise ValueError()
    except (ValueError, TypeError, KeyError):
        raise EpgError('astro_invalid_response_context') from None
    channels, contexts, programmes, rejected = {}, {}, [], Counter()
    for row in rows:
        service_id, name, number = row['id'], row.get('title'), row.get('stbNumber')
        if (not isinstance(name, str) or not 1 <= len(name.strip()) <= 256
                or not isinstance(number, str) or not re.fullmatch(r'\d{1,4}', number)
                or not isinstance(row.get('schedule'), list) or len(row['schedule']) > 7000):
            raise EpgError('astro_invalid_service_identity')
        original = 'astro:my:' + str(service_id)
        channels[original] = [name.strip()]
        contexts[original] = {'provider': 'astro-malaysia', 'serviceId': service_id,
            'channelNumber': number, 'countryCode': 'MY', 'regionCode': None,
            'sourceTimezone': 'Asia/Kuala_Lumpur', 'sourceCalendarTimezoneVerified': True,
            'contextVerifiedForCatalog': False}
        candidates, conflicts = {}, set()
        for event in row['schedule']:
            try:
                start, end = timestamp(event['eventStartMyt']), timestamp(event['eventEndMyt'])
                title, event_id = event['title'], event['siTrafficKey']
                if (not isinstance(title, str) or not 1 <= len(title.strip()) <= 512
                        or not isinstance(event_id, str) or not re.fullmatch(r'[0-9:]{1,100}', event_id)
                        or not 0 < end-start <= 86400):
                    raise ValueError()
                record = {'originalChannelId': original, 'title': title.strip(),
                    'startUtc': start, 'endUtc': end, 'endDerived': False,
                    'sourceEventId': event_id, 'sourceStart': event['eventStartMyt'],
                    'sourceStop': event['eventEndMyt'], 'sourceTimezone': '+08:00',
                    'serviceId': service_id, 'channelNumber': number,
                    'sourceUrl': API + '/channel/' + str(service_id) + '.json'}
                if event_id in candidates and candidates[event_id] != record:
                    conflicts.add(event_id)
                candidates[event_id] = record
            except (EpgError, ValueError, TypeError, KeyError):
                rejected['invalid_programme'] += 1
        ordered = sorted((p for key, p in candidates.items() if key not in conflicts),
                         key=lambda p: (p['startUtc'], p['sourceEventId']))
        rejected['conflicting_event_id'] += len(conflicts)
        overlaps = set()
        for i, event in enumerate(ordered):
            for following in ordered[i+1:]:
                if following['startUtc'] >= event['endUtc']:
                    break
                overlaps.update((event['sourceEventId'], following['sourceEventId']))
        for event in ordered:
            if event['sourceEventId'] in overlaps:
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


def success_refresh_delay(parsed, now, requested):
    """Keep the operator's interval unless a selected guide expires earlier."""
    ends = {identity: now for identity in parsed['channels']}
    for event in parsed['programmes']:
        ends[event['originalChannelId']] = max(ends[event['originalChannelId']], event['endUtc'])
    # Refresh before the shortest service runs out, keeping six hours for retries.
    return max(1800, min(requested, min(ends.values(), default=now)-now-6*3600))
