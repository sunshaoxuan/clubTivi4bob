"""Offline authored Astro contract fixtures. No real channel approvals."""
import json
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_astro as astro
from epg_ingest import EpgError

SOURCE = {'url': astro.DIRECTORY, 'serviceIds': [162, 172], 'countryCode': 'MY',
          'calendarTimezone': 'Asia/Kuala_Lumpur', 'redirectUrls': []}
NOW = astro.timestamp('2026-11-23T19:15:00+08:00')


def event(key='1:2:3', start='19:00:00', end='20:00:00'):
    return {'title': 'Fixture episode', 'eventStartMyt': '2026-11-23T'+start+'+08:00',
            'eventEndMyt': '2026-11-23T'+end+'+08:00', 'siTrafficKey': key,
            'programKey': 'Fixture123', 'description': 'Do not publish this text'}


def response(service_id, events=None):
    return {'responseCode': 200, 'response': {'id': service_id, 'title': 'Fixture '+str(service_id),
        'stbNumber': str(service_id), 'description': 'Do not retain',
        'schedule': {'2026-11-23': events if events is not None else
                     [event(), event('1:2:4', '20:00:00', '21:00:00')]}}}


def fetcher(source):
    sid = int(source['url'].split('/')[-1].split('.')[0])
    return json.dumps(response(sid)).encode(), {'serverDate': 'fixture'}


def test_one_contract_fetches_every_selected_service_and_projects_only_facts():
    calls = []
    def get(source):
        calls.append(source['url'])
        return fetcher(source)
    body, receipt = astro.fetch_schedule(SOURCE, NOW, get)
    assert calls == [astro.API+'/channel/162.json', astro.API+'/channel/172.json']
    assert receipt['pagesFetched'] == 2
    assert b'description' not in body and b'Do not' not in body
    parsed = astro.parse_schedule(body, SOURCE, NOW)
    assert parsed['quality']['currentAndFutureChannels'] == 2
    assert len(parsed['programmes']) == 4
    first = parsed['programmes'][0]
    assert first['startUtc'] == NOW-15*60
    assert first['endUtc'] == NOW+45*60
    assert first['sourceTimezone'] == '+08:00'
    assert first['sourceEventId'] == '1:2:3'


def test_missing_or_mismatched_service_cannot_produce_a_partial_success():
    def get(source):
        return json.dumps(response(999)).encode(), {}
    with pytest.raises(EpgError, match='astro_incomplete_service_response'):
        astro.fetch_schedule(SOURCE, NOW, get)
    body, _ = astro.fetch_schedule(SOURCE, NOW, fetcher)
    value = json.loads(body)
    value['services'].pop()
    with pytest.raises(EpgError, match='astro_invalid_response_context'):
        astro.parse_schedule(json.dumps(value).encode(), SOURCE, NOW)


def test_overlap_and_missing_timezone_are_quarantined_without_guessing():
    def get(source):
        sid = int(source['url'].split('/')[-1].split('.')[0])
        bad = event('1:2:5')
        bad['eventStartMyt'] = '2026-11-23T19:00:00'
        return json.dumps(response(sid, [event(), event('1:2:4', '19:30:00', '20:30:00'), bad])).encode(), {}
    body, _ = astro.fetch_schedule(SOURCE, NOW, get)
    parsed = astro.parse_schedule(body, SOURCE, NOW)
    assert parsed['programmes'] == []
    assert parsed['quality']['rejected']['invalid_programme'] == 2
    assert parsed['quality']['rejected']['overlapping_programme'] == 4


def test_rate_limit_retry_is_preserved_and_foreign_contract_is_rejected():
    def limited(_):
        raise EpgError('http_429', 1800)
    with pytest.raises(EpgError) as caught:
        astro.fetch_schedule(SOURCE, NOW, limited)
    assert caught.value.retry_after == 1800
    for update in ({'countryCode': 'SG'}, {'serviceIds': [172, 162]}, {'serviceIds': [True]},
                   {'url': 'https://other.example.org/channel/all.json'}):
        with pytest.raises(EpgError, match='invalid_astro_source_contract'):
            astro.validate_source({**SOURCE, **update})


def test_five_day_refresh_uses_the_shortest_service_horizon():
    def schedule(days):
        return {'channels': {'a': ['A'], 'b': ['B']}, 'programmes': [
            {'originalChannelId': 'a', 'endUtc': NOW+7*86400},
            {'originalChannelId': 'b', 'endUtc': NOW+days*86400}]}
    assert astro.success_refresh_delay(schedule(7), NOW, 5*86400) == 5*86400
    assert astro.success_refresh_delay(schedule(2), NOW, 5*86400) == 2*86400-6*3600
    assert astro.success_refresh_delay(schedule(0), NOW, 5*86400) == 1800
