"""Synthetic offline fixtures only; no real broadcaster schedule is published."""
import json
from pathlib import Path
import sys
from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
from epg_ingest import EpgError
import epg_rthk as rthk

DAY = '20261017'
NOW = int(datetime(2026, 10, 17, 10, 30, tzinfo=ZoneInfo('Asia/Hong_Kong')).timestamp())


def row(clocks='10:00-11:00', title='Fixture programme A'):
    return '<div class="showWrap"><span class="timeRow">'+clocks+'</span><div><a class="showTit" title="'+title+'"></a></div></div>'


def payload(html=None, key='31', extra=None):
    items = [{'key': key, 'data': row() if html is None else html}]
    if extra:
        items.extend(extra)
    return json.dumps({'result': items}).encode()


def parse(body):
    return rthk.parse_diagnostic(body, '31', DAY, now=NOW)


def test_explicit_bounds_provenance_and_no_permission_or_registration():
    result = parse(payload(row()+row('11:00-12:00', 'Fixture programme B')))
    assert result['quality']['currentAndFutureChannels'] == 1
    assert result['quality']['acceptedProgrammes'] == 2
    assert result['identity']['contextVerifiedForCatalog'] is False
    assert result['quality']['publicationAllowed'] is False
    assert result['quality']['programmeDataPermission'] == 'unverified'
    assert result['quality']['productionRegistered'] is False
    assert result['quality']['liveSourceValidated'] is False
    assert result['programmes'][0]['startUtc'] == NOW - 1800
    assert result['programmes'][0]['sourceCalendarTimezoneVerified'] is False
    assert result['programmes'][0]['endBasis'] == 'explicit_timeRow_end'


@pytest.mark.parametrize('channel', ['32', '310', '31+1', 31, '../31'])
def test_fixed_channel_and_no_fuzzy_identity(channel):
    with pytest.raises(EpgError, match='unreviewed_rthk_channel'):
        rthk.schedule_url(channel, DAY)


@pytest.mark.parametrize('day', ['20260230', '2026-10-17', '２０２６１０１７', '20261017?x=1'])
def test_invalid_dates(day):
    with pytest.raises(EpgError, match='invalid_schedule_date'):
        rthk.schedule_url('31', day)


@pytest.mark.parametrize('key', ['32', '031', 31])
def test_wrong_source_identity_never_falls_back(key):
    with pytest.raises(EpgError, match='rthk_exact_channel_required'):
        parse(payload(key=key))


def test_duplicate_source_identity_rejected_and_other_channels_ignored():
    with pytest.raises(EpgError, match='rthk_exact_channel_required'):
        parse(payload(extra=[{'key': '31', 'data': row()}]))
    result = parse(payload(extra=[{'key': '32', 'data': row(title='Wrong channel fixture')}]))
    assert [p['title'] for p in result['programmes']] == ['Fixture programme A']


@pytest.mark.parametrize('clocks', ['10:00', '10:00-10:00', '10:99-11:00', '24:00-24:30', '10:00-24:30', '00:00-23:59'])
def test_missing_invalid_or_overlong_bounds_are_not_inferred(clocks):
    result = parse(payload(row(clocks)+row('11:00-12:00', 'Next fixture')))
    assert len(result['programmes']) == 1
    assert result['programmes'][0]['title'] == 'Next fixture'


def test_midnight_rollover_and_explicit_24_hour_end():
    normal = parse(payload(row('23:30-00:30')))['programmes'][0]
    assert normal['endUtc']-normal['startUtc'] == 3600
    assert normal['endBasis'] == 'explicit_timeRow_one_midnight_rollover'
    terminal = parse(payload(row('23:00-24:00')))['programmes'][0]
    assert terminal['endUtc']-terminal['startUtc'] == 3600
    assert terminal['endBasis'] == 'explicit_timeRow_24_hour_end'


def test_no_gap_filling_empty_or_past_data_never_current_success():
    assert parse(payload(''))['quality']['acceptedProgrammes'] == 0
    past = parse(payload(row('00:00-01:00')))
    assert past['quality']['currentChannels'] == past['quality']['futureChannels'] == 0
    gaps = parse(payload(row()+row('14:00-15:00', 'Future fixture')))
    assert gaps['programmes'][0]['endUtc'] == NOW+1800
    assert len(gaps['programmes']) == 2


def test_idempotent_duplicate_conflict_and_overlap():
    assert parse(payload(row()+row()))['quality']['acceptedProgrammes'] == 1
    assert parse(payload(row()+row(title='Conflicting fixture')))['quality']['acceptedProgrammes'] == 0
    assert parse(payload(row()+row('10:30-11:30', 'Overlap fixture')))['quality']['acceptedProgrammes'] == 1


def test_title_entities_nested_clock_text_and_inert_url_attributes():
    html = row('10:<b>00</b>-11:00', 'Fixture &amp; A').replace('<a ', '<a href="https://127.0.0.1/private" onclick="ignored()" ')
    result = parse(payload(html))
    assert result['programmes'][0]['title'] == 'Fixture & A'
    assert 'href' not in result['programmes'][0]


def test_script_contaminated_row_and_duplicate_fields_quarantined():
    assert parse(payload(row().replace('</span>', '</span><script>ignored()</script>')))['quality']['acceptedProgrammes'] == 0
    assert parse(payload(row().replace('</span>', '</span><span class="timeRow">12:00-13:00</span>')))['quality']['acceptedProgrammes'] == 0


@pytest.mark.parametrize('body', [b'{}', b'[]', b'{', b'{"result":{}}'])
def test_invalid_container(body):
    with pytest.raises(EpgError):
        parse(body)


def test_size_depth_row_limits_and_unclosed_markup():
    with pytest.raises(EpgError, match='rthk_payload_size_limit'):
        parse(b'x'*(rthk.MAX_BYTES+1))
    with pytest.raises(EpgError, match='rthk_html_depth_limit'):
        parse(payload('<div>'*65+'</div>'*65))
    with pytest.raises(EpgError, match='rthk_row_limit'):
        parse(payload(row()*513))
    with pytest.raises(EpgError, match='malformed_rthk_html'):
        parse(payload(row()[:-6]))


def test_prototype_url_has_no_query_or_network_side_effect():
    assert rthk.schedule_url('31', DAY) == 'https://www.rthk.hk/timetable/main_timetable/20261017'
    assert not hasattr(rthk, 'fetch_schedule')


def test_deep_json_is_a_safe_parse_failure():
    with pytest.raises(EpgError, match='rthk_json_depth_limit'):
        parse(b'{"result":'+b'['*2000+b'0'+b']'*2000+b'}')


def test_json_depth_check_ignores_brackets_inside_quoted_html():
    title = '['*80+']'*80
    assert parse(payload(row(title=title)))['programmes'][0]['title'] == title


def test_duplicate_html_attributes_fail_closed():
    with pytest.raises(EpgError, match='ambiguous_rthk_html_attributes'):
        parse(payload(row().replace('class="showTit"', 'class="showTit" class="showTit"')))


@pytest.mark.parametrize('now', [True, 1.5, '20261017'])
def test_invalid_probe_clock_does_not_produce_coverage(now):
    with pytest.raises(EpgError, match='invalid_probe_time'):
        rthk.parse_diagnostic(payload(), '31', DAY, now=now)
