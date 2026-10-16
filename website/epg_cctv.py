"""Single-channel CNTV schedule diagnostic, never grants or publishes data.

The first live structure check covered cctv2 only. Keep that pilot scope fixed.
Source discovery reference is iptv-org/epg's tv.cctv.com adapter; upstream
programme-data permission remains independent of that project's code license.
"""
from collections import Counter
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import hashlib
import json
import re
import time
import urllib.error
import urllib.request
from zoneinfo import ZoneInfo

from epg_ingest import EpgError, NoRedirect, decode
from process_channel_inventory import _HTTPHandler, _HTTPSHandler
from source_registry import validate_public_url

API = 'https://api.cntv.cn/epg/getEpgInfoByChannelNew'
CHANNEL = 'cctv2'
NAME = 'CCTV-2 财经'
LIVE = 'https://tv.cctv.com/live/cctv2'
ZONE = ZoneInfo('Asia/Shanghai')
MAX_BYTES = 1024 * 1024


def schedule_url(channel, day):
    if channel != CHANNEL:
        raise EpgError('unreviewed_cctv_channel')
    if not isinstance(day, str) or not re.fullmatch(r'[0-9]{8}', day):
        raise EpgError('invalid_schedule_date')
    try:
        datetime.strptime(day, '%Y%m%d')
    except ValueError:
        raise EpgError('invalid_schedule_date') from None
    return API + '?serviceId=tvcctv&c=' + CHANNEL + '&d=' + day


def fetch_schedule(channel, day, opener=None, clock=time.monotonic):
    url = schedule_url(channel, day)
    validate_public_url(API)
    opener = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}),
        NoRedirect(), _HTTPHandler(), _HTTPSHandler())
    started = clock()
    try:
        response = opener.open(urllib.request.Request(url, headers={
            'User-Agent': 'BobTV-EPG-Validator/1.0', 'Accept': 'application/json',
            'Accept-Encoding': 'identity'}), timeout=8)
    except urllib.error.HTTPError as error:
        code = error.code
        raw_retry = error.headers.get('Retry-After', '')
        try:
            retry = int(raw_retry) if raw_retry.isdecimal() else max(0, int(parsedate_to_datetime(raw_retry).timestamp() - time.time()))
        except (ValueError, TypeError, OverflowError):
            retry = 0
        error.close()
        raise EpgError('http_' + str(code), retry) from None
    with response:
        if response.code != 200:
            raise EpgError('http_' + str(response.code))
        chunks, size = [], 0
        while True:
            if clock() - started > 12:
                raise EpgError('fetch_deadline')
            chunk = response.read(65536)
            if not chunk:
                break
            size += len(chunk)
            if size > MAX_BYTES:
                raise EpgError('compressed_size_limit')
            chunks.append(chunk)
        payload = b''.join(chunks)
        return payload, {'sourceUrl': url, 'fetchedAtUtc': int(time.time()),
            'rawSha256': hashlib.sha256(payload).hexdigest(), 'responseBytes': size,
            'cacheControl': response.headers.get('Cache-Control'),
            'programmeDataPermission': 'unverified', 'publicationAllowed': False}


def parse_schedule(payload, channel, day, now=None):
    url = schedule_url(channel, day)
    now = int(time.time() if now is None else now)
    if len(payload) > MAX_BYTES:
        raise EpgError('compressed_size_limit')
    decoded = decode(payload)
    if len(decoded) > 4 * MAX_BYTES:
        raise EpgError('expanded_size_limit')
    try:
        data = json.loads(decoded.decode('utf-8-sig'))
    except (UnicodeError, ValueError):
        raise EpgError('invalid_cctv_json') from None
    root = data.get('data') if isinstance(data, dict) else None
    if not isinstance(root, dict) or set(root) != {CHANNEL}:
        raise EpgError('cctv_channel_identity_mismatch')
    source = root[CHANNEL]
    if (not isinstance(source, dict) or source.get('channelName') != NAME
            or source.get('lvUrl') != LIVE):
        raise EpgError('cctv_channel_identity_mismatch')
    rows = source.get('list')
    if not isinstance(rows, list) or len(rows) > 256:
        raise EpgError('schedule_row_limit_or_type')
    slots, rejected = {}, Counter()
    for row in rows:
        try:
            if not isinstance(row, dict):
                raise EpgError('invalid_programme')
            start, stop, title = row.get('startTime'), row.get('endTime'), row.get('title')
            if type(start) is not int or type(stop) is not int or not 0 < stop - start <= 86400:
                raise EpgError('missing_or_invalid_explicit_bounds')
            if datetime.fromtimestamp(start, timezone.utc).astimezone(ZONE).strftime('%Y%m%d') != day:
                raise EpgError('source_day_mismatch')
            if not isinstance(title, str) or not 1 <= len(title.strip()) <= 512 or '\x00' in title:
                raise EpgError('missing_programme_title')
            item = {'originalChannelId': CHANNEL, 'title': title.strip(),
                'startUtc': start, 'endUtc': stop, 'sourceStart': start, 'sourceStop': stop,
                'sourceTimestampEncoding': 'unix_seconds_utc', 'sourceTimezone': 'Asia/Shanghai',
                'sourceTimezoneBasis': 'fixed_calendar_context_for_requested_day',
                'sourceDay': day, 'sourceUrl': url, 'endBasis': 'explicit_source_endTime',
                'originalEventId': row.get('eventId') if isinstance(row.get('eventId'), str) else None,
                'originalDisplayTime': row.get('showTime') if isinstance(row.get('showTime'), str) else None}
            if start in slots and slots[start] != item:
                slots[start] = None
                raise EpgError('conflicting_programme_slot')
            slots[start] = item
        except (EpgError, ValueError, OverflowError, OSError) as error:
            rejected[str(error) if isinstance(error, EpgError) else 'invalid_programme_time'] += 1
    ordered = sorted(slots.items())
    programmes = []
    for index, (_, item) in enumerate(ordered):
        if item is None:
            continue
        if index + 1 < len(ordered) and item['endUtc'] > ordered[index + 1][0]:
            rejected['overlapping_programme_bounds'] += 1
            continue
        programmes.append(item)
    current = any(p['startUtc'] <= now < p['endUtc'] for p in programmes)
    future = any(p['startUtc'] > now for p in programmes)
    return {'identity': {'id': CHANNEL, 'name': NAME, 'officialLivePage': LIVE,
            'countryCode': 'CN', 'sourceTimezone': 'Asia/Shanghai',
            'contextVerifiedForCatalog': False},
        'programmes': programmes,
        'quality': {'inputProgrammes': len(rows), 'acceptedProgrammes': len(programmes),
            'currentChannels': int(current), 'futureChannels': int(future),
            'currentAndFutureChannels': int(current and future), 'rejected': dict(rejected),
            'completeBroadcastSchedule': False, 'catalogMappingsApproved': 0,
            'sourceCalendarTimezoneVerified': False,
            'programmeDataPermission': 'unverified', 'publicationAllowed': False}}
