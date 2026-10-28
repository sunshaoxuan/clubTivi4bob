"""Authored offline markup, never a captured or fabricated live NCC schedule."""
from hashlib import sha256
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_ncc as ncc
from epg_ingest import EpgError


def span(clocks='10:00-11:00', title='Authored fixture A'):
    return '<span title="'+clocks+'"><a href="javascript:ignored()">'+title+'</a></span>'


def inspect(html):
    return ncc.inspect_span_bounds(html.encode())


def test_explicit_clock_observation_has_no_programmes_utc_or_approval():
    result = inspect(span())
    row = result['acceptedClockObservations'][0]
    assert row['startMinute'] == 600 and row['stopMinute'] == 660
    assert row['titleSha256'] == sha256(b'Authored fixture A').hexdigest()
    assert row['endBasis'] == 'explicit_span_title_pair'
    assert result['programmeRecords'] == []
    for key in ('sourceTimezoneVerified', 'exactChannelIdentityVerified',
                'dateSemanticsVerified', 'liveSourceValidated',
                'productionRegistered', 'publicationAllowed'):
        assert result[key] is False
    assert result['programmeDataPermission'] == 'unverified'
    assert not hasattr(ncc, 'fetch_schedule')


def test_ncc_diagnostic_cannot_be_selected_as_a_production_source():
    from epg_ingest import registry
    assert all('ncc' not in source['id'] and 'ncc' not in source.get('format', 'xmltv') for source in registry())


@pytest.mark.parametrize('separator', ['-', '~', '～', '至', '到', '－', '–'])
def test_authored_full_explicit_range_grammars(separator):
    assert len(inspect(span('10:00 '+separator+' 11:00'))['acceptedClockObservations']) == 1


@pytest.mark.parametrize('separator', ['~', '-', '～'])
def test_redacted_real_metadata_shape_has_one_complete_time_field(separator):
    # Authored labels, not real programme text or a captured response.
    metadata = 'Authored metadata(PG-0)、10:00'+separator+'11:00、Host:fixture、Category fixture'
    result = inspect(span(metadata))
    assert [r['startMinute'] for r in result['acceptedClockObservations']] == [600]
    assert result['programmeRecords'] == [] and result['liveSourceValidated'] is False


@pytest.mark.parametrize('metadata', [
    'Fixture、10:00-11:00、12:00-13:00',
    'Fixture、10:00-11:00、other clock 12:00',
    'Fixture、10:00-11:00、malformed clock 25:99',
    'Fixture、10:00-11:00、unicode clock １２：００',
])
def test_extra_clock_metadata_never_selects_a_convenient_pair(metadata):
    result = inspect(span(metadata))
    assert result['acceptedClockObservations'] == []
    assert result['rejected']['ncc_ambiguous_metadata_clock'] == 1


def test_metadata_field_count_missing_end_and_embedded_pair_are_bounded():
    for metadata in ('、'.join(['fixture']*8+['10:00-11:00']),
                     'Fixture、10:00、Host fixture',
                     'Fixture、label 10:00-11:00 suffix、Host fixture'):
        assert inspect(span(metadata))['acceptedClockObservations'] == []


@pytest.mark.parametrize('clocks', ['10:00', '10~11', '10:00-10:00',
    '10:60-11:00', '24:00-24:30', '10:00-24:30', '00:00-23:59',
    '10:00-11:00-12:00', '10:00-11:00 UTC', '１０:００-１１:００'])
def test_missing_or_ambiguous_bounds_never_filled(clocks):
    assert inspect(span(clocks))['acceptedClockObservations'] == []


def test_hourly_table_cells_are_not_programme_start_or_end():
    result = inspect('<table><tr><th>AM 10~11</th><td>Authored hourly bin</td></tr></table>')
    assert result['candidateSpans'] == 0 and result['acceptedClockObservations'] == []


def test_cross_midnight_explicit_pairs_and_24_hour_terminal():
    rolled = inspect(span('23:30-00:30'))['acceptedClockObservations'][0]
    assert rolled['stopMinute'] == 1470 and rolled['stopMinute']-rolled['startMinute'] == 60
    assert rolled['endBasis'].endswith('_one_midnight_rollover')
    terminal = inspect(span('23:00-24:00'))['acceptedClockObservations'][0]
    assert terminal['stopMinute'] == 1440 and terminal['endBasis'].endswith('_24_hour_end')


def test_identical_repeated_hour_spans_are_idempotent():
    body = span()+span()
    first = inspect(body)
    assert first == inspect(body)
    assert len(first['acceptedClockObservations']) == 1
    assert first['rejected']['duplicate_span'] == 1


def test_every_conflicting_overlap_removed_independent_of_input_order():
    a, b, c = span('10:00-12:00'), span('11:00-11:30', 'Authored fixture B'), span('12:00-13:00', 'Authored fixture C')
    first = inspect(a+b+c)
    assert first == inspect(c+b+a)
    assert first['rejected']['conflicting_span'] == 2
    assert [r['startMinute'] for r in first['acceptedClockObservations']] == [720]
    assert inspect(span()+span(title='Conflicting authored fixture'))['acceptedClockObservations'] == []


def test_gap_empty_and_past_only_do_not_produce_epg_coverage():
    assert inspect('<div></div>')['programmeRecords'] == []
    result = inspect(span('00:00-01:00')+span('03:00-04:00', 'Authored fixture B'))
    assert [r['stopMinute'] for r in result['acceptedClockObservations']] == [60, 240]
    assert result['programmeRecords'] == []


def test_nested_text_and_entities_hashed_without_following_links():
    row = inspect(span(title='<b>Authored</b> &amp; fixture<br>A'))['acceptedClockObservations'][0]
    assert row['titleSha256'] == sha256(b'Authored & fixture A').hexdigest()
    assert 'title' not in row and 'href' not in row


@pytest.mark.parametrize('tag', ['script', 'style', 'iframe', 'object', 'embed'])
def test_active_markup_contamination_rejected(tag):
    injected = span().replace('</a>', '</a><'+tag+'>'+'ignored'+('' if tag=='embed' else '</'+tag+'>'))
    assert inspect(injected)['acceptedClockObservations'] == []


def test_missing_overlong_title_and_duplicate_attributes_rejected():
    assert inspect(span(title=''))['acceptedClockObservations'] == []
    assert inspect(span(title='x'*(ncc.MAX_TITLE+1)))['acceptedClockObservations'] == []
    with pytest.raises(EpgError, match='ncc_ambiguous_attributes'):
        inspect(span().replace('<span ', '<span title="10:00-11:00" '))


def test_byte_depth_row_nested_span_and_malformed_limits():
    with pytest.raises(EpgError, match='ncc_payload_size_limit'):
        ncc.inspect_span_bounds(b'x'*(ncc.MAX_BYTES+1))
    with pytest.raises(EpgError, match='ncc_html_depth_limit'):
        inspect('<div>'*65+'</div>'*65)
    with pytest.raises(EpgError, match='ncc_row_limit'):
        inspect(span()*513)
    with pytest.raises(EpgError, match='ncc_nested_time_spans'):
        inspect(span(title=span()))
    with pytest.raises(EpgError, match='ncc_malformed_html'):
        inspect(span()[:-7])
    with pytest.raises(EpgError, match='ncc_invalid_utf8'):
        ncc.inspect_span_bounds(b'\xff')
