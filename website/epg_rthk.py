"""Offline-only RTHK TV31 conversion prototype, not a registered source.

Structure reference: iptv-org/epg sites/rthk.hk configuration and tests
(repository software licence: Unlicense). Programme-data permission, live
response calendar semantics and freshness are separate, unverified gates.
This module performs no requests, database writes, approvals or publication.
"""
from collections import Counter, defaultdict
from datetime import datetime, timedelta
from html.parser import HTMLParser
import json
import re
from zoneinfo import ZoneInfo

from epg_ingest import EpgError

BASE = 'https://www.rthk.hk/timetable/main_timetable/'
ZONE = ZoneInfo('Asia/Hong_Kong')
MAX_BYTES = 1024 * 1024
VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}


def schedule_url(channel, day):
    if channel != '31':
        raise EpgError('unreviewed_rthk_channel')
    if not isinstance(day, str) or not re.fullmatch(r'[0-9]{8}', day):
        raise EpgError('invalid_schedule_date')
    try:
        datetime.strptime(day, '%Y%m%d')
    except ValueError:
        raise EpgError('invalid_schedule_date') from None
    return BASE + day


class _Rows(HTMLParser):
    """Read inert attributes and clock text; never evaluate scripts or URLs."""
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.rows, self.current = [], [], None

    def handle_starttag(self, tag, attrs):
        if len(attrs) != len(dict(attrs)):
            raise EpgError('ambiguous_rthk_html_attributes')
        attrs = dict(attrs)
        classes = (attrs.get('class') or '').split()
        if tag not in VOID:
            self.stack.append(tag)
            if len(self.stack) > 64:
                raise EpgError('rthk_html_depth_limit')
        if 'showWrap' in classes:
            if self.current is not None or tag in VOID:
                raise EpgError('ambiguous_rthk_row_container')
            if len(self.rows) >= 512:
                raise EpgError('rthk_row_limit')
            self.current = {'root': len(self.stack), 'titles': [], 'times': [],
                'timeDepth': None, 'parts': [], 'unsafe': False}
        row = self.current
        if row is None:
            return
        if tag in {'script', 'style'}:
            row['unsafe'] = True
        if 'showTit' in classes:
            row['titles'].append(attrs.get('title'))
        if 'timeRow' in classes:
            if row['timeDepth'] is not None or tag in VOID:
                row['unsafe'] = True
            row['timeDepth'], row['parts'] = len(self.stack), []

    def handle_data(self, value):
        if self.current is not None and self.current['timeDepth'] is not None:
            self.current['parts'].append(value)

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if not self.stack or self.stack[-1] != tag:
            raise EpgError('malformed_rthk_html')
        row = self.current
        if row is not None:
            if row['timeDepth'] == len(self.stack):
                row['times'].append(''.join(row['parts']).strip())
                row['timeDepth'] = None
            if row['root'] == len(self.stack):
                self.rows.append(row)
                self.current = None
        self.stack.pop()


def _seconds(value, *, end=False):
    hour, minute = map(int, value.split(':'))
    if hour == 24 and minute == 0 and end:
        return 86400
    if hour > 23 or minute > 59:
        raise EpgError('invalid_rthk_clock')
    return hour * 3600 + minute * 60


def _check_json_depth(payload):
    depth, quoted, escaped = 0, False, False
    for value in payload:
        if quoted:
            if escaped:
                escaped = False
            elif value == 92:
                escaped = True
            elif value == 34:
                quoted = False
        elif value == 34:
            quoted = True
        elif value in (91, 123):
            depth += 1
            if depth > 64:
                raise EpgError('rthk_json_depth_limit')
        elif value in (93, 125):
            depth -= 1


def parse_diagnostic(payload, channel, day, *, now):
    """Normalize explicit fixture bounds, retaining unverified date provenance.

    The requested date path and reference timezone are recorded, not treated
    as independent live validation. The prototype cannot be selected by the
    production registry/parser and never fills missing programme intervals.
    """
    url = schedule_url(channel, day)
    if type(now) is not int:
        raise EpgError('invalid_probe_time')
    if not isinstance(payload, bytes) or not 1 <= len(payload) <= MAX_BYTES:
        raise EpgError('rthk_payload_size_limit')
    _check_json_depth(payload)
    try:
        value = json.loads(payload.decode('utf-8-sig'))
    except (UnicodeError, ValueError, RecursionError):
        raise EpgError('invalid_rthk_json') from None
    items = value.get('result') if isinstance(value, dict) else None
    if not isinstance(items, list) or len(items) > 32:
        raise EpgError('invalid_rthk_channel_container')
    matching = [item for item in items if isinstance(item, dict) and item.get('key') == channel]
    if len(matching) != 1 or not isinstance(matching[0].get('data'), str):
        raise EpgError('rthk_exact_channel_required')
    parser = _Rows()
    parser.feed(matching[0]['data'])
    parser.close()
    if parser.stack or parser.current is not None:
        raise EpgError('malformed_rthk_html')
    midnight = datetime.strptime(day, '%Y%m%d').replace(tzinfo=ZONE)
    rejected, slots = Counter(), defaultdict(list)
    for row in parser.rows:
        try:
            if row['unsafe'] or len(row['titles']) != 1 or len(row['times']) != 1:
                raise EpgError('ambiguous_rthk_row_fields')
            title = row['titles'][0]
            if not isinstance(title, str) or not 1 <= len(title.strip()) <= 512:
                raise EpgError('missing_programme_title')
            clocks = re.fullmatch(r'([0-9]{2}:[0-9]{2})\s*-\s*([0-9]{2}:[0-9]{2})', row['times'][0])
            if clocks is None:
                raise EpgError('missing_explicit_rthk_bounds')
            start, stop = _seconds(clocks[1]), _seconds(clocks[2], end=True)
            if start == stop:
                raise EpgError('ambiguous_rthk_equal_bounds')
            basis = 'explicit_timeRow_end'
            if stop < start:
                stop += 86400
                basis = 'explicit_timeRow_one_midnight_rollover'
            elif stop == 86400:
                basis = 'explicit_timeRow_24_hour_end'
            if not 0 < stop - start <= 8 * 3600:
                raise EpgError('rthk_duration_limit')
            beginning = int((midnight + timedelta(seconds=start)).timestamp())
            programme = {'originalChannelId': channel, 'title': ' '.join(title.split()),
                'startUtc': beginning, 'endUtc': int((midnight + timedelta(seconds=stop)).timestamp()),
                'sourceUrl': url, 'sourceTimezone': 'Asia/Hong_Kong', 'sourceDay': day,
                'originalDisplayTime': row['times'][0], 'endBasis': basis,
                'dateBasis': 'requested_date_path_not_independently_live_verified',
                'sourceCalendarTimezoneVerified': False, 'publicationAllowed': False}
            slots[beginning].append(programme)
        except EpgError as exc:
            rejected[str(exc)] += 1
    programmes = []
    for _, entries in sorted(slots.items()):
        unique = {json.dumps(entry, sort_keys=True): entry for entry in entries}
        if len(unique) != 1:
            rejected['conflicting_rthk_slot'] += len(entries)
            continue
        programme = next(iter(unique.values()))
        if programmes and programme['startUtc'] < programmes[-1]['endUtc']:
            rejected['overlapping_rthk_slot'] += 1
            continue
        programmes.append(programme)
    current = any(p['startUtc'] <= now < p['endUtc'] for p in programmes)
    future = any(p['startUtc'] > now for p in programmes)
    return {'identity': {'id': channel, 'name': 'RTHK TV 31', 'countryCode': 'HK',
        'sourceTimezone': 'Asia/Hong_Kong', 'contextVerifiedForCatalog': False},
        'programmes': programmes, 'quality': {'inputProgrammes': len(parser.rows),
        'acceptedProgrammes': len(programmes), 'currentChannels': int(current),
        'futureChannels': int(future), 'currentAndFutureChannels': int(current and future),
        'rejected': dict(rejected), 'sourceCalendarTimezoneVerified': False,
        'programmeDataPermission': 'unverified', 'completeBroadcastSchedule': False,
        'publicationAllowed': False, 'liveSourceValidated': False, 'productionRegistered': False}}
