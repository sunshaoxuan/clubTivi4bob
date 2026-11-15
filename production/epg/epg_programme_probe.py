"""Bounded programme content inspection. Evidence never grants feed mappings."""
from datetime import datetime, timezone
import json
import re
from xml.etree import ElementTree as ET


def _time(value):
    if type(value) in (int, float):
        value = value / 1000 if value > 10**12 else value
        if 0 <= value <= 4102444800:
            return int(value)
    if isinstance(value, str) and re.search(r'(Z|[+-]\d\d:\d\d)$', value):
        try:
            return int(datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp())
        except (ValueError, OverflowError):
            return None
    return None


def inspect_programme_content(raw, content_type, now):
    result = {'contentInspectionVersion': 2, 'method': 'GET',
        'programmeIdentityApproved': False, 'published': False}
    from epg_ingest import decode, EpgError
    try:
        raw = decode(raw)
    except EpgError:
        return {**result, 'result': 'response_read_invalid_encoding', 'validIntervalRecords': 0}
    if 'json' in content_type or raw.lstrip().startswith((b'{', b'[')):
        try:
            root = json.loads(raw)
        except (ValueError, UnicodeError):
            return {**result, 'result': 'response_read_invalid_json', 'validIntervalRecords': 0}
        stack, records, scanned = [root], [], 0
        while stack and scanned < 20000:
            item = stack.pop(); scanned += 1
            if isinstance(item, dict):
                start = next((_time(item[k]) for k in ('starts_at','startUtc','start','startTime','airstamp') if k in item), None)
                end = next((_time(item[k]) for k in ('ends_at','endUtc','stopUtc','stop','end','endTime') if k in item), None)
                title = next((item[k] for k in ('title','name') if isinstance(item.get(k), str)), None)
                if start is not None and end is not None and title and 0 < end-start <= 86400:
                    records.append((start, end))
                stack.extend(item.values())
            elif isinstance(item, list):
                stack.extend(item[:10000])
        return {**result, 'result': 'programme_intervals_read_requires_feed_review' if records
                else 'response_read_request_contract_unresolved',
            'validIntervalRecords': len(records),
            'currentIntervalRecords': sum(a <= now < b for a,b in records),
            'futureIntervalRecords': sum(a > now for a,b in records),
            'inspectionTruncated': bool(stack),
            'nextAction': 'verify_exact_channel_edition_and_schema' if records else 'trace_parameters_pagination_or_client_contract'}
    if b'<tv' in raw[:8192]:
        from epg_ingest import parse_xmltv, EpgError
        try:
            parsed = parse_xmltv(raw, now)
            return {**result, 'result': 'xmltv_content_read_requires_feed_review',
                'quality': parsed['quality'], 'nextAction': 'verify_exact_channel_edition_and_source_context'}
        except (EpgError, ValueError, ET.ParseError):
            return {**result, 'result': 'response_read_invalid_xmltv', 'nextAction': 'review_schema_and_dates'}
    return {**result, 'result': 'page_read_client_contract_required',
            'nextAction': 'inspect_official_page_scripts_public_api_and_pagination'}
