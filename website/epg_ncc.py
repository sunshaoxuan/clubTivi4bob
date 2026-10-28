"""Offline NCC span-bound diagnostic, not a registered programme source.

Bounded public PTS-main responses carry explicit clock ranges in span.title.
A real diagnostic found that the pair is one field of ideographic-comma
delimited metadata. The revised field selector is tested on authored redacted
structure, not yet revalidated on live bytes. Title/date/calendar semantics
remain unapproved. These checks do not grant rights or normalize programmes.
No network, database, timezone assumption or publication path exists here.
"""
from collections import Counter
from hashlib import sha256
from html.parser import HTMLParser
import re

from epg_ingest import EpgError

MAX_BYTES = 1024 * 1024
MAX_ROWS = 512
MAX_DEPTH = 64
MAX_TITLE = 512
VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link',
        'meta', 'param', 'source', 'track', 'wbr'}
CLOCK_PAIR = re.compile(r'([0-9]{2}:[0-9]{2})\s*[-~～至到－–]\s*([0-9]{2}:[0-9]{2})')


class _Spans(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.rows, self.current = [], [], None

    def handle_starttag(self, tag, attrs):
        if len(attrs) != len(dict(attrs)):
            raise EpgError('ncc_ambiguous_attributes')
        values = dict(attrs)
        if tag not in VOID:
            self.stack.append(tag)
            if len(self.stack) > MAX_DEPTH:
                raise EpgError('ncc_html_depth_limit')
        if tag == 'span' and 'title' in values:
            if self.current is not None:
                raise EpgError('ncc_nested_time_spans')
            if len(self.rows) >= MAX_ROWS:
                raise EpgError('ncc_row_limit')
            self.current = {'depth': len(self.stack), 'clockPair': values['title'],
                            'parts': [], 'textLength': 0, 'unsafe': False}
        row = self.current
        if row is not None:
            if tag in {'script', 'style', 'iframe', 'object', 'embed'}:
                row['unsafe'] = True
            if tag == 'br':
                self.handle_data(' ')

    def handle_data(self, value):
        if self.current is not None:
            row = self.current
            row['textLength'] += len(value)
            if row['textLength'] > MAX_TITLE:
                row['unsafe'] = True
            else:
                row['parts'].append(value)

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if not self.stack or self.stack[-1] != tag:
            raise EpgError('ncc_malformed_html')
        if self.current is not None and self.current['depth'] == len(self.stack):
            self.rows.append(self.current)
            self.current = None
        self.stack.pop()


def _minutes(value, *, end=False):
    hour, minute = map(int, value.split(':'))
    if end and hour == 24 and minute == 0:
        return 1440
    if hour > 23 or minute > 59:
        raise EpgError('ncc_invalid_clock')
    return hour * 60 + minute


def _explicit_pair(value):
    """Select one complete time field, never arbitrary clock substrings.

    Real diagnostic evidence: <metadata>、HH:MM~HH:MM、<metadata>.
    No metadata is interpreted as programme identity or a timezone. Extra
    clock-bearing metadata is ambiguous even if one field has a valid pair.
    """
    value = (value or '').strip()
    direct = CLOCK_PAIR.fullmatch(value)
    if direct is not None:
        return direct
    fields = [part.strip() for part in value.split('、')]
    if not 2 <= len(fields) <= 8:
        raise EpgError('ncc_missing_explicit_bounds')
    pairs = [(index, CLOCK_PAIR.fullmatch(field)) for index, field in enumerate(fields)]
    matches = [(index, match) for index, match in pairs if match is not None]
    if not matches:
        raise EpgError('ncc_missing_explicit_bounds')
    if len(matches) != 1:
        raise EpgError('ncc_ambiguous_metadata_clock')
    selected, match = matches[0]
    if any(re.search(r'\d[:：]\d', field) for index, field in enumerate(fields) if index != selected):
        raise EpgError('ncc_ambiguous_metadata_clock')
    return match


def inspect_span_bounds(payload):
    """Inspect complete input as local clock observations, never as UTC EPG.

    Only a full explicit clock pair or a single complete field of delimited
    metadata is accepted. Missing ends, hourly table labels, malformed clocks
    and equal bounds are never inferred. Repeated
    identical span rows are deduplicated. All conflicting overlaps are removed,
    since input order cannot identify which row is authoritative. The returned
    title hashes allow conflict diagnostics without persisting programme text.
    """
    if not isinstance(payload, bytes) or not 1 <= len(payload) <= MAX_BYTES:
        raise EpgError('ncc_payload_size_limit')
    try:
        text = payload.decode('utf-8-sig')
    except UnicodeError:
        raise EpgError('ncc_invalid_utf8') from None
    parser = _Spans()
    parser.feed(text)
    parser.close()
    if parser.stack or parser.current is not None:
        raise EpgError('ncc_malformed_html')
    rejected, unique = Counter(), {}
    for row in parser.rows:
        try:
            if row['unsafe']:
                raise EpgError('ncc_unsafe_span')
            clocks = _explicit_pair(row['clockPair'])
            title = ' '.join(''.join(row['parts']).split())
            if not 1 <= len(title) <= MAX_TITLE:
                raise EpgError('ncc_missing_title')
            start, stop = _minutes(clocks[1]), _minutes(clocks[2], end=True)
            if start == stop:
                raise EpgError('ncc_equal_bounds')
            basis = 'explicit_span_title_pair'
            if stop < start:
                stop += 1440
                basis = 'explicit_span_title_pair_one_midnight_rollover'
            elif stop == 1440:
                basis = 'explicit_span_title_pair_24_hour_end'
            if not 0 < stop - start <= 8 * 60:
                raise EpgError('ncc_duration_limit')
            key = (start, stop, sha256(title.encode()).hexdigest())
            if key in unique:
                rejected['duplicate_span'] += 1
            else:
                unique[key] = {'startMinute': start, 'stopMinute': stop,
                               'titleSha256': key[2], 'endBasis': basis}
        except EpgError as error:
            rejected[str(error)] += 1
    values = sorted(unique.values(), key=lambda r: (r['startMinute'], r['stopMinute'], r['titleSha256']))
    conflicts = set()
    for index, row in enumerate(values):
        for other in range(index + 1, len(values)):
            if values[other]['startMinute'] >= row['stopMinute']:
                break
            conflicts.update((index, other))
    rejected['conflicting_span'] += len(conflicts)
    return {'candidateSpans': len(parser.rows),
            'acceptedClockObservations': [r for index, r in enumerate(values) if index not in conflicts],
            'rejected': {key: value for key, value in rejected.items() if value},
            'programmeRecords': [], 'programmeDataPermission': 'unverified',
            'sourceTimezoneVerified': False, 'exactChannelIdentityVerified': False,
            'dateSemanticsVerified': False, 'liveSourceValidated': False,
            'productionRegistered': False, 'publicationAllowed': False}
