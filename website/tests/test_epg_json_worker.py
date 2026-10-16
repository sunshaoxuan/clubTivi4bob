import json
from pathlib import Path
import subprocess
import sys

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_ingest as epg
import epg_tvmaze as tv
import epg_discovery as discovery

NOW = 1792135200
SOURCE = {'id': 'json-gb', 'url': tv.API, 'format': 'tvmaze-json',
    'countryCode': 'GB', 'calendarTimezone': 'Europe/London', 'redirectUrls': [],
    'refreshSeconds': 3600, 'publicationAllowed': False,
    'dataLicense': {'status': 'evidence_found', 'name': 'CC BY-SA 4.0'}}


def body(start='2026-10-16T10:00:00Z', airtime='11:00'):
    return json.dumps([{'id': 1, 'name': 'Episode', 'airstamp': start,
        'airdate': '2026-10-16', 'airtime': airtime, 'runtime': 60,
        'show': {'name': 'Show', 'network': {'id': 5, 'name': 'One',
            'country': {'code': 'GB', 'timezone': 'Europe/London'}}}}]).encode()


def test_partial_future_is_internal_metadata_not_current_or_public_coverage(tmp_path):
    result = epg.probe_batch(tmp_path, [SOURCE], NOW, lambda _: (body(), {'cacheControl': 'public, max-age=3600'}))
    row = result['sources'][0]
    quality = json.loads(row['last_good_quality'])
    assert row['state'] == 'partial' and row['failures'] == 0
    assert row['last_success'] == NOW and row['next_retry'] == NOW + 3600
    assert quality['futureChannels'] == 1 and quality['currentAndFutureChannels'] == 0
    assert quality['completeBroadcastSchedule'] is False and result['published'] is False
    assert epg.probe_batch(tmp_path, [SOURCE], NOW + 3599, lambda _: pytest.fail('must not fetch fresh cached output'))['attemptedSources'] == 0
    with epg.database(tmp_path) as conn:
        assert conn.execute('SELECT count(*) FROM source_identities').fetchone()[0] == 1
        saved = json.loads(conn.execute('SELECT context_json FROM source_identity_context').fetchone()[0])
        assert saved['countryCode'] == 'GB' and saved['sourceTimezone'] == 'Europe/London'
        assert conn.execute("SELECT count(*) FROM sqlite_master WHERE name='epg_programmes'").fetchone()[0] == 0
        _, ids, names = discovery.source_index(conn, NOW)
        channel = {'name': 'One', 'epgId': None, 'countryCode': 'GB', 'regionCode': None}
        proposals = discovery.candidates_for(channel, ids, names)
        assert len(proposals) == 1 and proposals[0]['sourceIdentityContext']['countryCode'] == 'GB'
        assert not proposals[0]['contextVerified'] and not proposals[0]['automaticallyApplied']
        assert discovery.candidates_for({**channel, 'countryCode': 'US'}, ids, names) == []
        assert discovery.candidates_for({**channel, 'countryCode': None}, ids, names) == []


def test_empty_cached_json_and_stale_only_are_failed_but_not_refetched_each_minute(tmp_path):
    first = epg.probe_batch(tmp_path, [SOURCE], NOW, lambda _: (body(), {}))['sources'][0]
    for index, payload in enumerate([b'[]', body('2026-10-16T00:00:00Z', '01:00')], 1):
        row = epg.probe_batch(tmp_path, [SOURCE], NOW + index * 3600, lambda _: (payload, {}))['sources'][0]
        assert row['state'] == 'failed'
        assert row['last_success'] == NOW and row['last_good_quality'] == first['last_good_quality']
        assert row['next_retry'] >= NOW + (index + 1) * 3600
    with epg.database(tmp_path) as conn:
        assert conn.execute('SELECT count(*) FROM source_identities').fetchone()[0] == 1


def test_default_dispatch_uses_reviewed_country_and_local_calendar_date(tmp_path, monkeypatch):
    calls = []
    def checked(country, day):
        calls.append((country, day))
        return body(), {}
    monkeypatch.setattr(tv, 'fetch_schedule', checked)
    epg.probe_batch(tmp_path, [SOURCE], NOW)
    assert calls == [('GB', '2026-10-16')]
    assert epg.source_day({**SOURCE, 'calendarTimezone': 'Asia/Shanghai'}, epg.timestamp('20261016233000 +0000')) == '2026-10-17'


def test_us_diagnostic_registry_is_fixed_hourly_and_never_approves_mapping_or_publication():
    source = next(s for s in epg.registry() if s['id'] == 'tvmaze-us-diagnostic-v1')
    assert source['url'] == tv.API and source['format'] == 'tvmaze-json'
    assert source['countryCode'] == 'US' and source['calendarTimezone'] == 'America/New_York'
    assert source['refreshSeconds'] == 3600 and source['publicationAllowed'] is False
    assert source['redirectUrls'] == []
    assert source['dataLicense']['name'] == 'CC BY-SA 4.0'
    # Country calendar does not silently use the UTC date at a local midnight.
    assert epg.source_day(source, epg.timestamp('20261016010000 +0000')) == '2026-10-15'


@pytest.mark.parametrize('change', [
    {'url': 'https://unreviewed.example.org/schedule'}, {'countryCode': 'GB&other=1'},
    {'calendarTimezone': 'not/a/zone'}, {'refreshSeconds': 900},
    {'redirectUrls': ['https://api.tvmaze.com/other']}, {'format': 'arbitrary'},
])
def test_registry_rejects_unreviewed_json_configuration(tmp_path, change):
    path = tmp_path / 'sources.json'
    path.write_text(json.dumps({'schemaVersion': 1, 'sources': [{**SOURCE, **change}]}))
    with pytest.raises(epg.EpgError):
        epg.registry(path)


def test_cli_lazy_adapter_preserves_shared_error_identity_and_retry_after(tmp_path):
    path = tmp_path / 'sources.json'
    path.write_text(json.dumps({'schemaVersion': 1, 'sources': [SOURCE]}))
    script = str(Path(epg.__file__))
    wrapper = '''import runpy,sys,types
from pathlib import Path
sys.path.insert(0,str(Path(sys.argv[1]).parent))
stub=types.ModuleType('epg_tvmaze')
def limited(*args):
 import epg_ingest
 raise epg_ingest.EpgError('http_429',900)
stub.fetch_schedule=limited
sys.modules['epg_tvmaze']=stub
sys.argv=sys.argv[1:]
runpy.run_path(sys.argv[0],run_name='__main__')
'''
    result = subprocess.run([sys.executable, '-c', wrapper, script, '--registry', str(path),
        '--data-dir', str(tmp_path / 'db')], capture_output=True, text=True, timeout=15, check=True)
    row = json.loads(result.stdout)['sources'][0]
    assert row['last_error'] == 'http_429'
    assert row['next_retry'] - row['last_attempt'] >= 900


def test_json_source_never_reads_legacy_xmltv_cache(tmp_path):
    cache = tmp_path / 'cache'
    cache.mkdir()
    assert epg.seed_cached_identities(tmp_path / 'db', [SOURCE], cache, NOW) == []
