import io
import json
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_tvmaze as tv
from epg_ingest import EpgError

NOW = 1792135200  # 2026-10-16 07:20 UTC


def episode(**changes):
    row = {'id': 1, 'name': 'Episode One', 'airstamp': '2026-10-16T07:00:00+00:00',
        'airdate': '2026-10-16', 'airtime': '08:00', 'runtime': 60,
        'show': {'name': 'Morning Show', 'network': {'id': 5, 'name': 'One',
            'country': {'code': 'GB', 'timezone': 'Europe/London'}}}}
    return {**row, **changes}


def parse(rows, **kwargs):
    return tv.parse_schedule(json.dumps(rows).encode(), 'GB', '2026-10-16', NOW, **kwargs)


def test_explicit_stamp_runtime_license_and_no_synthetic_gap_fill():
    rows = [episode(), episode(id=2, airstamp='2026-10-16T10:00:00+00:00', airtime='11:00')]
    result = parse(rows)
    assert result['quality']['currentAndFutureNetworks'] == 1
    assert not result['quality']['completeBroadcastSchedule']
    assert len(result['programmes']) == 2
    first = result['programmes'][0]
    assert first['endUtc'] - first['startUtc'] == 3600
    assert first['endBasis'] == 'start_plus_explicit_episode_runtime'
    assert first['shareAlikeRequired'] and first['licenseUrl'] == tv.LICENSE
    assert first['sourceUrl'] == 'https://www.tvmaze.com/episodes/1'
    assert result['programmes'][1]['startUtc'] - first['endUtc'] == 7200
    assert result['identities'][0]['contextVerifiedForCatalog'] is False
    assert result['quality']['catalogMappingsApproved'] == 0


@pytest.mark.parametrize('changes,code', [
    ({'runtime': None}, 'missing_explicit_episode_runtime'),
    ({'runtime': True}, 'missing_explicit_episode_runtime'),
    ({'runtime': 0}, 'missing_explicit_episode_runtime'),
    ({'runtime': 1441}, 'missing_explicit_episode_runtime'),
    ({'airstamp': '2026-10-16T07:00:00'}, 'missing_explicit_timezone'),
    ({'airdate': '2026-10-15'}, 'source_local_time_mismatch'),
    ({'airtime': '07:00'}, 'source_local_time_mismatch'),
    ({'id': None}, 'invalid_episode_identity'),
    ({'show': {'name': 'Show', 'webChannel': {'id': 1}, 'network': None}}, 'not_linear_network'),
])
def test_incomplete_or_contradictory_facts_are_not_completed(changes, code):
    result = parse([episode(**changes)])
    assert result['programmes'] == []
    assert result['quality']['rejected'][code] == 1


def test_wrong_country_and_different_region_network_are_not_mapped():
    row = episode()
    row['show']['network']['country']['code'] = 'US'
    assert parse([row])['quality']['rejected'] == {'network_country_mismatch': 1}
    row = episode()
    row['show']['network']['name'] = 'One Scotland +1'
    assert parse([row])['identities'][0]['name'] == 'One Scotland +1'
    assert not parse([row])['identities'][0]['contextVerifiedForCatalog']


def test_identity_and_slot_conflicts_quarantine_prior_rows_and_duplicates_deduplicate():
    assert len(parse([episode(), episode()])['programmes']) == 1
    changed = episode(id=2)
    changed['show']['network']['name'] = 'Different regional network'
    assert parse([episode(), changed])['programmes'] == []
    result = parse([episode(), episode(id=2), episode()])
    assert result['programmes'] == []


def test_overlap_and_stale_only_false_success_are_visible():
    result = parse([episode(), episode(id=2, airstamp='2026-10-16T07:30:00Z', airtime='08:30')])
    assert len(result['programmes']) == 1
    assert result['quality']['rejected']['overlapping_episode_runtime'] == 1
    stale = tv.parse_schedule(json.dumps([episode()]).encode(), 'GB', '2026-10-16', NOW + 86400)
    assert stale['quality']['currentAndFutureNetworks'] == 0
    assert stale['quality']['publicationAllowed'] is False


@pytest.mark.parametrize('country,day', [
    ('GB&other=1', '2026-10-16'), ('https://private', '2026-10-16'),
    ('gb', '2026-10-16'), ('GB', '2026-02-30'), ('GB', '2026-10-16&url=private'),
])
def test_only_fixed_host_and_strict_scalar_country_date(country, day):
    with pytest.raises(EpgError):
        tv.schedule_url(country, day)


class Response(io.BytesIO):
    def __init__(self, body=b'[]', code=200, headers=None):
        super().__init__(body)
        self.code, self.headers = code, headers or {}


class Opener:
    def __init__(self, response):
        self.response, self.urls = response, []
    def open(self, req, timeout):
        assert timeout == 8
        self.urls.append(req.full_url)
        return self.response


def test_fetch_does_not_follow_redirect_and_obeys_limits_retry_cache_metadata(monkeypatch):
    opener = Opener(Response(code=302, headers={'Location': 'http://127.0.0.1/private'}))
    with pytest.raises(EpgError, match='http_302'):
        tv.fetch_schedule('GB', '2026-10-16', opener)
    assert opener.urls == ['https://api.tvmaze.com/schedule?country=GB&date=2026-10-16']
    with pytest.raises(EpgError) as err:
        tv.fetch_schedule('GB', '2026-10-16', Opener(Response(code=429, headers={'Retry-After': '900'})))
    assert err.value.retry_after == 900
    _, receipt = tv.fetch_schedule('GB', '2026-10-16', Opener(Response(headers={'Cache-Control': 'public, max-age=3600'})))
    assert receipt['cacheControl'].endswith('3600') and not receipt['publicationAllowed']
    times = iter([0, 33])
    with pytest.raises(EpgError, match='fetch_deadline'):
        tv.fetch_schedule('GB', '2026-10-16', Opener(Response()), clock=lambda: next(times))
    monkeypatch.setattr(tv, 'MAX_COMPRESSED', 1)
    with pytest.raises(EpgError, match='compressed_size_limit'):
        tv.fetch_schedule('GB', '2026-10-16', Opener(Response()))


def test_dst_repeated_hour_uses_explicit_instant_and_network_timezone():
    rows = [episode(airstamp='2026-10-25T00:30:00Z', airdate='2026-10-25', airtime='01:30', runtime=30),
        episode(id=2, airstamp='2026-10-25T01:30:00Z', airdate='2026-10-25', airtime='01:30', runtime=30)]
    result = tv.parse_schedule(json.dumps(rows).encode(), 'GB', '2026-10-25', NOW)
    assert len(result['programmes']) == 2
    assert result['programmes'][1]['startUtc'] - result['programmes'][0]['startUtc'] == 3600


def test_us_dst_repeated_hour_retains_explicit_instants_without_broadcast_gap_fill():
    rows = [episode(airstamp='2026-11-01T05:30:00Z', airdate='2026-11-01', airtime='01:30', runtime=30),
        episode(id=2, airstamp='2026-11-01T06:30:00Z', airdate='2026-11-01', airtime='01:30', runtime=30)]
    for row in rows:
        row['show']['network']['country'] = {'code': 'US', 'timezone': 'America/New_York'}
    result = tv.parse_schedule(json.dumps(rows).encode(), 'US', '2026-11-01', NOW)
    assert len(result['programmes']) == 2
    assert result['programmes'][1]['startUtc'] - result['programmes'][0]['startUtc'] == 3600
    assert result['programmes'][0]['endUtc'] < result['programmes'][1]['startUtc']
    assert result['identities'][0]['sourceTimezone'] == 'America/New_York'
    assert result['quality']['catalogMappingsApproved'] == 0


@pytest.mark.parametrize('identity,name', [(72, 'Syndication'), (72, 'Renamed distribution bucket'), (999, 'Syndication')])
def test_syndication_bucket_is_not_a_concrete_broadcast_channel(identity, name):
    row = episode()
    row['show']['network'].update({'id': identity, 'name': name,
        'country': {'code': 'US', 'timezone': 'America/New_York'}})
    row.update({'airstamp': '2026-10-16T12:00:00Z', 'airtime': '08:00'})
    result = tv.parse_schedule(json.dumps([row]).encode(), 'US', '2026-10-16', NOW)
    assert result['programmes'] == [] and result['identities'] == []
    assert result['quality']['rejected'] == {'nonspecific_syndication_network': 1}
