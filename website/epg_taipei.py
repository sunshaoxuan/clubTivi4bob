"""Two exact Taipei radio services from the licensed official monthly CSV.

Only the fixed dataset and its current, explicitly titled month are followed.
Weekday recurrence is bounded by that published month, never extrapolated.
"""
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta
from email.utils import parsedate_to_datetime
import csv
import hashlib
from html.parser import HTMLParser
import io
import json
import re
import time
import urllib.error
import urllib.request
from urllib.parse import unquote, urlsplit
from zoneinfo import ZoneInfo

from epg_ingest import EpgError, NoRedirect
from process_channel_inventory import _HTTPHandler, _HTTPSHandler

SOURCE_ID = 'taipei-radio-opendata-v1'
DATASET = 'https://data.gov.tw/dataset/121175'
METADATA = 'https://data.taipei/dataset/detail?id=536e992c-7087-451c-a0aa-f47aa98406ac'
RESOURCE_PREFIX = 'https://data.taipei/api/frontstage/tpeod/dataset/resource.download?rid='
LICENSE = 'Open Government Data License 1.0'
ZONE = ZoneInfo('Asia/Taipei')
WEEKDAYS = {'Mon': 0, 'Tue': 1, 'Wed': 2, 'Thu': 3, 'Fri': 4, 'Sat': 5, 'Sun': 6}
CHANNELS = {'FM': ('taipei-fm93-1', ['臺北廣播電臺 FM93.1', '台北广播电台FM93.1']),
            'AM': ('taipei-am1134', ['臺北廣播電臺 AM1134', '台北广播电台AM1134'])}
TITLE = re.compile(r'(\d{3})年(\d{1,2})月臺北廣播電臺中文節目表')
UUID = re.compile(r'[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}')


def success_refresh_delay(now, refresh_seconds):
    """Recheck a new published month when the old recurrence bounds expire.

    Ordinary intra-month cadence is unchanged. This applies only to successful
    fetches; provider Retry-After and failure backoff must never be shortened.
    """
    local = datetime.fromtimestamp(now, ZONE)
    year, month = (local.year + 1, 1) if local.month == 12 else (local.year, local.month + 1)
    boundary = int(datetime(year, month, 1, tzinfo=ZONE).timestamp())
    return min(refresh_seconds, max(1, boundary - now))


def credit_for_title(title):
    match = TITLE.fullmatch(title)
    if not match: raise EpgError('taipei_resource_title_mismatch')
    return {'sourceLabel': f'臺北廣播電臺 {int(match[1]) + 1911} {title}',
        'attributionUrl': DATASET, 'licenseUrl': 'https://data.gov.tw/license',
        'modificationNotice': '臺北廣播電臺每月中文節目表。依原始月份、星期及明示起止時間展開，標準化為 UTC；去重並剔除衝突，未補造缺漏節目。',
        'shareAlikeRequired': False}


def refresh_existing_credit(conn, title):
    """Refresh a resource version label only; never create or change a grant."""
    row = conn.execute('''SELECT a.metadata FROM epg_data_attributions a
      JOIN epg_data_grants g ON g.source_id=a.source_id
      WHERE a.source_id=? AND g.revoked=0 AND g.source_url=? AND g.evidence_url=? AND g.data_license=?''',
        (SOURCE_ID, DATASET, DATASET, LICENSE)).fetchone()
    if not row: return False
    previous, updated = json.loads(row[0]), credit_for_title(title)
    if any(previous.get(key) != value for key, value in updated.items() if key != 'sourceLabel'):
        raise EpgError('taipei_attribution_review_changed')
    if previous == updated: return False
    with conn:
        conn.execute('UPDATE epg_data_attributions SET metadata=? WHERE source_id=?',
            (json.dumps(updated, sort_keys=True), SOURCE_ID))
    return True


class ResourceRows(HTMLParser):
    def __init__(self):
        super().__init__(); self.rows = []; self.row = None; self.depth = 0

    def handle_starttag(self, tag, attrs):
        if tag == 'tr':
            self.depth += 1
            if self.row is None: self.row = {'text': [], 'links': []}
        if self.row is not None and tag == 'a':
            href = dict(attrs).get('href', '')
            if href.startswith(RESOURCE_PREFIX): self.row['links'].append(href)

    def handle_endtag(self, tag):
        if tag == 'tr' and self.row is not None:
            self.depth -= 1
            if self.depth == 0:
                self.rows.append(self.row); self.row = None

    def handle_data(self, value):
        if self.row is not None: self.row['text'].append(value)


def resource_for_month(html, current_day):
    parser = ResourceRows(); parser.feed(html)
    found = set()
    for row in parser.rows:
        text = ''.join(row['text'])
        match = TITLE.search(text)
        if not match or (int(match[1]) + 1911, int(match[2])) != (current_day.year, current_day.month):
            continue
        for url in row['links']:
            rid = url.removeprefix(RESOURCE_PREFIX)
            if UUID.fullmatch(rid): found.add((url, match[0]))
    if len(found) != 1:
        raise EpgError('taipei_current_month_resource_unverified')
    return next(iter(found))


def _read(url, limit, opener, started, clock):
    if url != METADATA and not (url.startswith(RESOURCE_PREFIX)
            and UUID.fullmatch(url.removeprefix(RESOURCE_PREFIX))):
        raise EpgError('unreviewed_taipei_url')
    try:
        response = opener.open(urllib.request.Request(url, headers={
            'User-Agent': 'BobTV-EPG-Validator/1.0', 'Accept-Encoding': 'identity'}), timeout=8)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        if response.code != 200:
            retry = response.headers.get('Retry-After', '')
            try:
                retry = int(retry) if retry.isdecimal() else max(0, int(parsedate_to_datetime(retry).timestamp() - time.time()))
            except (ValueError, TypeError, OverflowError): retry = 0
            raise EpgError('http_' + str(response.code), max(0, retry))
        if response.geturl() != url:
            raise EpgError('unreviewed_redirect')
        chunks, count = [], 0
        while True:
            if clock() - started > 24: raise EpgError('fetch_deadline')
            chunk = response.read(32 * 1024)
            if not chunk: break
            count += len(chunk)
            if count > limit: raise EpgError('compressed_size_limit')
            chunks.append(chunk)
        return b''.join(chunks), dict(response.headers)


def fetch_schedule(now, opener=None, clock=time.monotonic):
    opener = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}),
        NoRedirect(), _HTTPHandler(), _HTTPSHandler())
    started = clock()
    raw_metadata, _ = _read(METADATA, 1024 * 1024, opener, started, clock)
    try:
        source_url, title = resource_for_month(raw_metadata.decode('utf-8'), datetime.fromtimestamp(now, ZONE).date())
        raw, headers = _read(source_url, 64 * 1024, opener, started, clock)
        disposition = unquote(headers.get('Content-Disposition', ''))
        if title not in disposition: raise EpgError('taipei_resource_title_mismatch')
        body = raw.decode('utf-8')
    except UnicodeError:
        raise EpgError('unsupported_encoding') from None
    value = {'schemaVersion': 1, 'sourceUrl': source_url, 'resourceTitle': title,
        'csv': body, 'csvSha256': hashlib.sha256(raw).hexdigest(),
        'metadataSha256': hashlib.sha256(raw_metadata).hexdigest()}
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True).encode()
    return payload, {'sourceUrl': source_url, 'finalUrl': source_url,
        'datasetUrl': DATASET, 'metadataUrl': METADATA, 'resourceTitle': title,
        'csvSha256': value['csvSha256'], 'metadataSha256': value['metadataSha256'],
        'cacheControl': headers.get('Cache-Control'), 'licenseUrl': 'https://data.gov.tw/license'}


def _seconds(value, end=False):
    if not isinstance(value, str) or not re.fullmatch(r'\d{6}', value):
        raise EpgError('taipei_invalid_time')
    if end and value == '240000': return 86400
    hour, minute, second = int(value[:2]), int(value[2:4]), int(value[4:])
    if hour > 23 or minute > 59 or second > 59: raise EpgError('taipei_invalid_time')
    return hour * 3600 + minute * 60 + second


def parse_schedule(payload, now):
    if not isinstance(payload, bytes) or not 0 < len(payload) <= 256 * 1024:
        raise EpgError('taipei_payload_limit')
    try:
        value = json.loads(payload)
        if not isinstance(value, dict) or value.get('schemaVersion') != 1:
            raise ValueError()
        match = TITLE.fullmatch(value['resourceTitle'])
        if not match or not isinstance(value['csv'], str) or not value['sourceUrl'].startswith(RESOURCE_PREFIX):
            raise ValueError()
        if not UUID.fullmatch(value['sourceUrl'].removeprefix(RESOURCE_PREFIX)): raise ValueError()
        if (len(value['csv'].encode()) > 64 * 1024
                or hashlib.sha256(value['csv'].encode()).hexdigest() != value['csvSha256']):
            raise EpgError('taipei_csv_checksum_mismatch')
        month = date(int(match[1]) + 1911, int(match[2]), 1)
        day = datetime.fromtimestamp(now, ZONE).date()
        if (month.year, month.month) != (day.year, day.month):
            raise EpgError('taipei_month_expired_or_future')
        reader = csv.DictReader(io.StringIO(value['csv'].removeprefix('\ufeff')))
        if reader.fieldnames != ['chanel', 'week', 'start_time', 'end_time', 'program', 'DJ']:
            raise EpgError('taipei_csv_schema_changed')
        rows = list(reader)
        if not 1 <= len(rows) <= 1000: raise EpgError('taipei_row_limit')
    except EpgError:
        raise
    except (ValueError, TypeError, KeyError, OverflowError, csv.Error):
        raise EpgError('taipei_invalid_envelope') from None
    rejected, candidates = Counter(), defaultdict(list)
    for index, row in enumerate(rows, 1):
        try:
            if row['chanel'] not in CHANNELS: raise EpgError('taipei_unknown_channel')
            tokens = row['week'].split('、')
            if not tokens or len(set(tokens)) != len(tokens) or any(t not in WEEKDAYS for t in tokens):
                raise EpgError('taipei_invalid_weekday')
            title = row['program'].strip()
            if not 1 <= len(title) <= 512: raise EpgError('invalid_programme')
            first, last = _seconds(row['start_time']), _seconds(row['end_time'], True)
            if last == 0 and first > 0: last = 86400
            if last <= first: raise EpgError('taipei_invalid_interval')
            identity = CHANNELS[row['chanel']][0]
            for offset in range(-2, 8):
                scheduled = day + timedelta(days=offset)
                if (scheduled.year, scheduled.month) != (month.year, month.month) or scheduled.weekday() not in {WEEKDAYS[t] for t in tokens}:
                    continue
                midnight = datetime.combine(scheduled, datetime.min.time(), ZONE)
                start, stop = int((midnight + timedelta(seconds=first)).timestamp()), int((midnight + timedelta(seconds=last)).timestamp())
                if stop < now - 2 * 86400: continue
                candidates[identity].append({'originalChannelId': identity, 'title': title,
                    'startUtc': start, 'endUtc': stop, 'sourceTimezone': 'Asia/Taipei',
                    'sourceStart': (midnight + timedelta(seconds=first)).isoformat(),
                    'sourceStop': (midnight + timedelta(seconds=last)).isoformat(),
                    'endBasis': 'explicit_monthly_weekday_bounds', 'sourceUrl': value['sourceUrl'],
                    'resourceTitle': value['resourceTitle'], 'sourceCsvRow': index,
                    'originalSourceChannelField': row['chanel'],
                    'sourceWeekdays': tokens, 'sourceMonth': month.strftime('%Y-%m'),
                    'recurrenceBasis': 'publisher_named_month_and_explicit_weekday_time_fields',
                    'csvSha256': value['csvSha256']})
        except (EpgError, AttributeError, TypeError) as error:
            rejected[str(error) if isinstance(error, EpgError) else 'taipei_invalid_row'] += 1
    programmes, current_conflicts = [], []
    for identity, records in candidates.items():
        unique = {}
        for row in records:
            key = (row['startUtc'], row['endUtc'], row['title'])
            if key in unique: rejected['duplicate_record'] += 1
            else: unique[key] = row
        records = sorted(unique.values(), key=lambda r: (r['startUtc'], r['endUtc'], r['title']))
        conflicts = set()
        for index, row in enumerate(records):
            for other_index in range(index + 1, len(records)):
                other = records[other_index]
                if other['startUtc'] >= row['endUtc']: break
                conflicts.update((index, other_index))
        rejected['conflicting_slot'] += len(conflicts)
        # Diagnostic facts only. Never resolve an overlap by CSV order or infer
        # a split time from two titles sharing the same explicit hour.
        current_conflicts.extend({key: row[key] for key in
            ('originalChannelId', 'title', 'startUtc', 'endUtc', 'sourceCsvRow',
             'sourceStart', 'sourceStop', 'sourceUrl', 'csvSha256')}
            for index, row in enumerate(records)
            if index in conflicts and row['startUtc'] <= now < row['endUtc'])
        programmes.extend(row for index, row in enumerate(records) if index not in conflicts)
    current = {p['originalChannelId'] for p in programmes if p['startUtc'] <= now < p['endUtc']}
    future = {p['originalChannelId'] for p in programmes if p['startUtc'] > now}
    return {'channels': {identity: names for identity, names in CHANNELS.values()},
        'identityContexts': {identity: {'countryCode': 'TW', 'regionCode': None,
            'sourceTimezone': 'Asia/Taipei', 'broadcastBand': band,
            'contextVerifiedForCatalog': False} for band, (identity, _) in CHANNELS.items()},
        'programmes': programmes, 'quality': {'inputRows': len(rows),
            'acceptedProgrammes': len(programmes), 'usableChannels': 2,
            'currentChannels': len(current), 'futureChannels': len(future),
            'currentAndFutureChannels': len(current & future),
            'coverageStartUtc': min((p['startUtc'] for p in programmes), default=None),
            'coverageEndUtc': max((p['endUtc'] for p in programmes), default=None),
            'resourceTitle': value['resourceTitle'], 'recurrenceBoundedToPublishedMonth': True,
            'currentConflictRecords': current_conflicts,
            'rejected': dict(rejected)}}
