"""CNTV schedule diagnostics that never grant or publish data.

Scheduled production checks retain the original cctv2 scope. The explicit
research batch can check the individually identified services from the official
timetable and emit source-level quality metrics for operator review.
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
RESEARCH_NAMES = {
    'cctv1': 'CCTV-1 综合',
    'cctv2': NAME,
    'cctv3': 'CCTV-3 综艺',
    'cctv4': 'CCTV-4 (亚洲)',
    'cctv5': 'CCTV-5 体育',
    'cctv5plus': 'CCTV-5+ 体育赛事',
    'cctv6': 'CCTV-6 电影',
    'cctv7': 'CCTV-7 国防军事',
    'cctv8': 'CCTV-8 电视剧',
    'cctvjilu': 'CCTV-9 纪录',
    'cctv10': 'CCTV-10 科教',
    'cctv11': 'CCTV-11 戏曲',
    'cctv12': 'CCTV-12 社会与法',
    'cctv13': 'CCTV-13 新闻',
    'cctvchild': 'CCTV-14 少儿',
    'cctv15': 'CCTV-15 音乐',
    'cctv16': 'CCTV-16奥林匹克',
    'cctv17': 'CCTV-17农业农村',
    'cctveurope': 'CCTV-4 (欧洲)',
    'cctvamerica': 'CCTV-4 (美洲)',
}
INDEX_LIVE_PAGES = frozenset({'cctv5', 'cctv5plus', 'cctv16'})


def schedule_url(channel, day, *, research=False):
    if channel != CHANNEL and (not research or not isinstance(channel, str) or channel not in RESEARCH_NAMES):
        raise EpgError('unreviewed_cctv_channel')
    if not isinstance(day, str) or not re.fullmatch(r'[0-9]{8}', day):
        raise EpgError('invalid_schedule_date')
    try:
        datetime.strptime(day, '%Y%m%d')
    except ValueError:
        raise EpgError('invalid_schedule_date') from None
    return API + '?serviceId=tvcctv&c=' + channel + '&d=' + day


def fetch_schedule(channel, day, opener=None, clock=time.monotonic, *, research=False):
    url = schedule_url(channel, day, research=research)
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


def parse_schedule(payload, channel, day, now=None, *, research=False):
    url = schedule_url(channel, day, research=research)
    name = RESEARCH_NAMES[channel]
    live = 'https://tv.cctv.com/live/' + channel
    if channel in INDEX_LIVE_PAGES:
        live += '/index.shtml'
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
    if not isinstance(root, dict) or set(root) != {channel}:
        raise EpgError('cctv_channel_identity_mismatch')
    source = root[channel]
    if (not isinstance(source, dict) or source.get('channelName') != name
            or source.get('lvUrl') != live):
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
            local_start = datetime.fromtimestamp(start, timezone.utc).astimezone(ZONE)
            if local_start.strftime('%Y%m%d') != day:
                raise EpgError('source_day_mismatch')
            if research and row.get('showTime') != local_start.strftime('%H:%M'):
                raise EpgError('source_display_time_mismatch')
            if not isinstance(title, str) or not 1 <= len(title.strip()) <= 512 or '\x00' in title:
                raise EpgError('missing_programme_title')
            item = {'originalChannelId': channel, 'title': title.strip(),
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
    return {'identity': {'id': channel, 'name': name, 'officialLivePage': live,
            'countryCode': 'CN', 'sourceTimezone': 'Asia/Shanghai',
            'contextVerifiedForCatalog': False},
        'programmes': programmes,
        'quality': {'inputProgrammes': len(rows), 'acceptedProgrammes': len(programmes),
            'currentChannels': int(current), 'futureChannels': int(future),
            'currentAndFutureChannels': int(current and future), 'rejected': dict(rejected),
            'completeBroadcastSchedule': False, 'catalogMappingsApproved': 0,
            'sourceCalendarTimezoneVerified': False,
            'programmeDataPermission': 'unverified', 'publicationAllowed': False}}
