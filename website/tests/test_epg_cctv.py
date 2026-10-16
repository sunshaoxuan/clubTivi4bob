import gzip
import io
import json
from pathlib import Path
import sys
import subprocess

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_cctv as cctv
import epg_ingest as ingest
import epg_discovery as discovery
import epg_source_recovery as recovery
import urllib.error
from epg_ingest import EpgError

NOW = 1792156800
DAY = '20261016'
SOURCE = {'id': 'cctv2-official-diagnostic-v1', 'url': cctv.API,
    'format': 'cctv-json', 'channelId': 'cctv2', 'countryCode': 'CN',
    'calendarTimezone': 'Asia/Shanghai', 'redirectUrls': [], 'refreshSeconds': 3600,
    'publicationAllowed': False, 'dataLicense': {'status': 'unverified'}}


def row(start=NOW - 60, stop=NOW + 60, title='Fixture programme'):
    return {'startTime': start, 'endTime': stop, 'title': title,
        'eventId': 'fixture', 'showTime': 'fixture-display-time'}


def payload(rows=None, **changes):
    source = {'channelName': cctv.NAME, 'lvUrl': cctv.LIVE,
        'list': rows if rows is not None else [row(), row(NOW + 60, NOW + 120, 'Next fixture')]}
    source.update(changes)
    return json.dumps({'data': {'cctv2': source}}).encode()


def parse(body):
    return cctv.parse_schedule(body, 'cctv2', DAY, NOW)


def test_explicit_epoch_bounds_and_source_provenance_no_mapping_or_permission():
    result = parse(payload())
    assert result['quality']['currentAndFutureChannels'] == 1
    assert result['quality']['acceptedProgrammes'] == 2
    assert result['identity']['contextVerifiedForCatalog'] is False
    assert result['quality']['publicationAllowed'] is False
    assert result['quality']['programmeDataPermission'] == 'unverified'
    assert result['quality']['sourceCalendarTimezoneVerified'] is False
    assert result['programmes'][0]['endBasis'] == 'explicit_source_endTime'
    assert result['programmes'][0]['sourceTimestampEncoding'] == 'unix_seconds_utc'
    assert result['programmes'][0]['originalDisplayTime'] == 'fixture-display-time'


@pytest.mark.parametrize('channel', ['cctv1', 'cctv5', 'cctv5plus', 'CCTV2', '../cctv2', 'cctv2&c=cctv5'])
def test_fixed_pilot_scope_cannot_expand_url_or_other_channel(channel):
    with pytest.raises(EpgError, match='unreviewed_cctv_channel'):
        cctv.schedule_url(channel, DAY)


@pytest.mark.parametrize('day', ['20260230', '2026-10-16', '20261016&x=1', '２０２６１０１６'])
def test_invalid_date_rejected(day):
    with pytest.raises(EpgError, match='invalid_schedule_date'):
        cctv.schedule_url('cctv2', day)


@pytest.mark.parametrize('changes', [{'channelName': 'CCTV-5 体育'}, {'lvUrl': 'https://example.test/cctv2'}])
def test_explicit_identity_mismatch_rejected(changes):
    with pytest.raises(EpgError, match='cctv_channel_identity_mismatch'):
        parse(payload(**changes))


def test_missing_end_not_inferred_from_next_and_empty_or_stale_not_success():
    missing = row()
    del missing['endTime']
    result = parse(payload([missing, row(NOW + 60, NOW + 120)]))
    assert result['quality']['acceptedProgrammes'] == 1
    assert result['quality']['currentAndFutureChannels'] == 0
    assert parse(payload([]))['quality']['acceptedProgrammes'] == 0
    stale = parse(payload([row(NOW - 600, NOW - 300)]))
    assert stale['quality']['currentChannels'] == stale['quality']['futureChannels'] == 0


def test_duplicates_conflicts_overlap_and_wrong_day():
    first = row()
    assert parse(payload([first, first]))['quality']['acceptedProgrammes'] == 1
    assert parse(payload([first, row(title='Conflict')]))['quality']['acceptedProgrammes'] == 0
    overlapping = parse(payload([first, row(NOW, NOW + 100)]))
    assert overlapping['quality']['acceptedProgrammes'] == 1
    result = parse(payload([row(NOW + 86400, NOW + 86500)]))
    assert result['quality']['rejected'] == {'source_day_mismatch': 1}


def test_cross_midnight_end_preserved_without_shift_or_future_fabrication():
    start = 1792166340  # 2026-10-16 23:59 in the requested calendar.
    result = parse(payload([row(start, start + 120)]))
    assert result['programmes'][0]['endUtc'] == start + 120


@pytest.mark.parametrize('body', [b'{}', b'[]', b'{"data":{"cctv5":{}}}'])
def test_malformed_or_wrong_channel_container_rejected(body):
    with pytest.raises(EpgError, match='cctv_channel_identity_mismatch'):
        parse(body)


def test_size_limits_bound_wire_and_expansion():
    with pytest.raises(EpgError, match='compressed_size_limit'):
        parse(b'x' * (cctv.MAX_BYTES + 1))
    with pytest.raises(EpgError, match='expanded_size_limit'):
        parse(gzip.compress(b' ' * (4 * cctv.MAX_BYTES + 1)))


class Response(io.BytesIO):
    def __init__(self, body, code=200):
        super().__init__(body)
        self.code = code
        self.headers = {'Cache-Control': 'public, max-age=3600'}


class Opener:
    def __init__(self, body=b'{}', code=200):
        self.body, self.code, self.requests = body, code, []

    def open(self, request, timeout):
        self.requests.append((request, timeout))
        return Response(self.body, self.code)


def test_fetch_validates_fixed_public_base_and_never_widens_parameter_scope(monkeypatch):
    validated = []
    monkeypatch.setattr(cctv, 'validate_public_url', validated.append)
    opener = Opener(payload())
    body, metadata = cctv.fetch_schedule('cctv2', DAY, opener)
    assert validated == [cctv.API]
    assert opener.requests[0][0].full_url == cctv.API + '?serviceId=tvcctv&c=cctv2&d=' + DAY
    assert opener.requests[0][1] == 8
    assert metadata['publicationAllowed'] is False and body == opener.body


@pytest.mark.parametrize('status', [302, 403, 429])
def test_non_success_or_redirect_is_not_accepted(monkeypatch, status):
    monkeypatch.setattr(cctv, 'validate_public_url', lambda url: None)
    with pytest.raises(EpgError, match='http_' + str(status)):
        cctv.fetch_schedule('cctv2', DAY, Opener(code=status))


def test_fetch_limits_wire_and_elapsed_time(monkeypatch):
    monkeypatch.setattr(cctv, 'validate_public_url', lambda url: None)
    with pytest.raises(EpgError, match='compressed_size_limit'):
        cctv.fetch_schedule('cctv2', DAY, Opener(b'x' * (cctv.MAX_BYTES + 1)))
    times = iter([0, 13])
    with pytest.raises(EpgError, match='fetch_deadline'):
        cctv.fetch_schedule('cctv2', DAY, Opener(), clock=lambda: next(times))


def test_background_probe_retains_only_unapproved_identity_metadata(tmp_path):
    result = ingest.probe_batch(tmp_path, [SOURCE], NOW,
        lambda _: (payload([row(NOW + 60, NOW + 120)]), {}))
    receipt = result['sources'][0]
    assert receipt['state'] == 'partial' and receipt['next_retry'] == NOW + 3600
    assert result['published'] is False
    with ingest.database(tmp_path) as conn:
        context = json.loads(conn.execute('SELECT context_json FROM source_identity_context').fetchone()[0])
        assert context['id'] == 'cctv2' and context['countryCode'] == 'CN'
        assert context['sourceCalendarTimezoneVerified'] is False
        assert context['contextVerifiedForCatalog'] is False
        generation, ids, names = discovery.source_index(conn, NOW)
        proposals = discovery.candidates_for({'epgId': 'CCTV-2', 'name': 'CCTV-2', 'countryCode': 'CN'}, ids, names)
        assert len(proposals) == 1 and proposals[0]['originalChannelId'] == 'cctv2'
        assert not proposals[0]['programmeDataRightsVerified'] and not proposals[0]['contextVerified']
        assert discovery.candidates_for({'epgId': 'CCTV-5', 'name': 'CCTV-5', 'countryCode': 'CN'}, ids, names) == []
        for table in ('epg_programmes', 'epg_source_payloads', 'epg_mapping_approvals', 'epg_data_grants'):
            if conn.execute('SELECT 1 FROM sqlite_master WHERE name=?', (table,)).fetchone():
                assert conn.execute('SELECT count(*) FROM ' + table).fetchone()[0] == 0
    assert ingest.probe_batch(tmp_path, [SOURCE], NOW + 3599,
        lambda _: pytest.fail('cooldown must prevent duplicate fetch'))['attemptedSources'] == 0


def test_stale_http_success_and_timeout_retain_last_good_and_backoff(tmp_path):
    first = ingest.probe_batch(tmp_path, [SOURCE], NOW, lambda _: (payload(), {}))['sources'][0]
    stale = ingest.probe_batch(tmp_path, [SOURCE], NOW + 3600,
        lambda _: (payload([row(NOW - 600, NOW - 300)]), {}))['sources'][0]
    assert stale['state'] == 'failed' and stale['last_success'] == NOW
    assert stale['last_good_quality'] == first['last_good_quality']
    assert stale['next_retry'] >= NOW + 7200
    def timeout(_):
        raise TimeoutError()
    failed = ingest.probe_batch(tmp_path, [SOURCE], stale['next_retry'], timeout)['sources'][0]
    assert failed['last_error'] == 'network_failure' and failed['last_success'] == NOW
    retry = failed['next_retry']
    recovered = ingest.probe_batch(tmp_path, [SOURCE], retry,
        lambda _: (payload([row(retry - 10, retry + 10), row(retry + 10, retry + 60)]), {}))['sources'][0]
    assert recovered['state'] == 'healthy' and recovered['failures'] == 0
    with ingest.database(tmp_path) as conn:
        assert conn.execute('SELECT count(*) FROM probe_audit').fetchone()[0] == 8


@pytest.mark.parametrize('code', ['http_401', 'http_403'])
def test_access_denial_stays_manual_without_retries_or_data_deletion(tmp_path, code):
    def denied(_):
        raise EpgError(code)
    receipt = ingest.probe_batch(tmp_path, [SOURCE], NOW, denied)['sources'][0]
    assert receipt['state'] == 'manual_review' and receipt['last_success'] is None
    assert ingest.probe_batch(tmp_path, [SOURCE], NOW + 86400,
        lambda _: pytest.fail('manual review cannot retry automatically'))['attemptedSources'] == 0


def test_retry_after_and_manually_seeded_cooldown_survive_timer_ticks(tmp_path):
    with ingest.database(tmp_path) as conn:
        conn.execute('INSERT INTO source_health(id,url,configuration,next_retry) VALUES(?,?,?,?)',
            (SOURCE['id'], SOURCE['url'], json.dumps(SOURCE, sort_keys=True), NOW + 3600))
    assert ingest.probe_batch(tmp_path, [SOURCE], NOW,
        lambda _: pytest.fail('manual probe cooldown'))['attemptedSources'] == 0
    def limited(_):
        raise EpgError('http_429', 7200)
    limited_receipt = ingest.probe_batch(tmp_path, [SOURCE], NOW + 3600, limited)['sources'][0]
    assert limited_receipt['next_retry'] >= NOW + 10800
    assert limited_receipt['last_error'] == 'http_429'


@pytest.mark.parametrize('change', [
    {'url': 'https://example.test/schedule'}, {'id': 'other-cctv'}, {'channelId': 'cctv5'},
    {'calendarTimezone': 'UTC'}, {'countryCode': 'HK'}, {'redirectUrls': ['https://api.cntv.cn/other']},
    {'refreshSeconds': 900},
])
def test_registry_rejects_pilot_scope_expansion(tmp_path, monkeypatch, change):
    monkeypatch.setattr(ingest, 'validate_public_url', lambda url: None)
    target = tmp_path / 'sources.json'
    target.write_text(json.dumps({'schemaVersion': 1, 'sources': [{**SOURCE, **change}]}))
    with pytest.raises(EpgError, match='invalid_cctv_source'):
        ingest.registry(target)


def test_fixed_recovery_country_and_no_legacy_xml_cache(tmp_path):
    assert recovery.country_scope(SOURCE) == 'CN'
    assert recovery.country_scope({**SOURCE, 'channelId': 'cctv5'}) is None
    assert ingest.seed_cached_identities(tmp_path / 'db', [SOURCE], tmp_path / 'missing', NOW) == []


@pytest.mark.parametrize('dated', [False, True])
def test_fetch_preserves_numeric_and_http_date_retry_after(monkeypatch, dated):
    from email.utils import formatdate
    monkeypatch.setattr(cctv, 'validate_public_url', lambda url: None)
    monkeypatch.setattr(cctv.time, 'time', lambda: NOW)
    class Limited:
        def open(self, request, timeout):
            raise urllib.error.HTTPError(request.full_url, 429, 'fixture',
                {'Retry-After': formatdate(NOW + 7200, usegmt=True) if dated else '7200'}, io.BytesIO(b''))
    with pytest.raises(EpgError, match='http_429') as error:
        cctv.fetch_schedule('cctv2', DAY, Limited())
    assert error.value.retry_after == 7200


def test_default_worker_dispatch_keeps_fixed_channel_and_calendar(tmp_path, monkeypatch):
    calls = []
    def checked(channel, day):
        calls.append((channel, day))
        return payload(), {}
    monkeypatch.setattr(cctv, 'fetch_schedule', checked)
    receipt = ingest.probe_batch(tmp_path, [SOURCE], NOW)['sources'][0]
    assert receipt['state'] == 'healthy' and calls == [('cctv2', DAY)]


def test_cli_cctv_lazy_import_keeps_shared_safe_error_and_retry(tmp_path):
    registry = tmp_path / 'sources.json'
    registry.write_text(json.dumps({'schemaVersion': 1, 'sources': [SOURCE]}))
    wrapper = '''import runpy,sys,types
from pathlib import Path
sys.path.insert(0,str(Path(sys.argv[1]).parent))
stub=types.ModuleType('epg_cctv')
def limited(*args):
 import epg_ingest
 raise epg_ingest.EpgError('http_429',7200)
stub.fetch_schedule=limited
sys.modules['epg_cctv']=stub
sys.argv=sys.argv[1:]
runpy.run_path(sys.argv[0],run_name='__main__')
'''
    result = subprocess.run([sys.executable, '-c', wrapper, str(Path(ingest.__file__)),
        '--registry', str(registry), '--data-dir', str(tmp_path / 'db')],
        capture_output=True, text=True, timeout=15, check=True)
    receipt = json.loads(result.stdout)['sources'][0]
    assert receipt['last_error'] == 'http_429'
    assert receipt['next_retry'] >= receipt['last_attempt'] + 7200
