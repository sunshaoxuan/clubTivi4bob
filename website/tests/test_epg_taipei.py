"""Authored fixtures only; no real programmes or network access."""
from contextlib import closing
from datetime import datetime
import hashlib
import json
from pathlib import Path
import sys
from zoneinfo import ZoneInfo
import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_taipei as t
from epg_ingest import EpgError, parse_source, registry

NOW = int(datetime(2026, 10, 17, 7, 30, tzinfo=ZoneInfo('Asia/Taipei')).timestamp())
URL = t.RESOURCE_PREFIX + '00000000-0000-4000-8000-000000000001'
HEADER = 'chanel,week,start_time,end_time,program,DJ\n'


def envelope(rows, title='115年10月臺北廣播電臺中文節目表'):
    body = HEADER + '\n'.join(rows) + '\n'
    return json.dumps({'schemaVersion': 1, 'resourceTitle': title, 'sourceUrl': URL,
        'csv': body, 'csvSha256': hashlib.sha256(body.encode()).hexdigest()}).encode()


def test_current_future_explicit_month_weekday_time_and_cross_midnight():
    value = t.parse_schedule(envelope([
        'FM,Sat,070000,080000,Fixture current,Fixture host',
        'FM,Sat,080000,090000,Fixture future,Fixture host',
        'AM,Sat,070000,080000,Fixture AM current,Fixture host',
        'AM,Sat,230000,000000,Fixture midnight,Fixture host']), NOW)
    assert value['quality']['currentAndFutureChannels'] == 2
    assert all(p['sourceTimezone'] == 'Asia/Taipei' and p['endBasis'] == 'explicit_monthly_weekday_bounds' for p in value['programmes'])
    midnight = next(p for p in value['programmes'] if p['title'] == 'Fixture midnight')
    assert midnight['endUtc'] - midnight['startUtc'] == 3600
    assert midnight['sourceStop'].endswith('00:00:00+08:00')
    assert all(p['sourceMonth'] == '2026-10' for p in value['programmes'])


def test_duplicate_records_are_idempotent_and_all_conflicting_slots_are_removed():
    body = envelope(['FM,Sat,070000,080000,Fixture stable,',
        'FM,Sat,070000,080000,Fixture stable,',
        'FM,Sat,080000,100000,Fixture conflicting broad,',
        'FM,Sat,090000,093000,Fixture conflicting narrow,',
        'FM,Sat,100000,110000,Fixture valid future,'])
    first = t.parse_schedule(body, NOW)
    assert first == t.parse_schedule(body, NOW)
    assert first['quality']['rejected']['duplicate_record'] > 0
    assert first['quality']['rejected']['conflicting_slot'] > 0
    assert {p['title'] for p in first['programmes']} == {'Fixture stable', 'Fixture valid future'}


def test_current_conflict_diagnostics_preserve_exact_rows_without_filling_slot():
    value = t.parse_schedule(envelope([
        'FM,Sat,070000,080000,Fixture first,',
        'FM,Sat,070000,080000,Fixture second,',
        'FM,Sat,080000,090000,Fixture future,',
        'AM,Sun,070000,080000,Fixture unrelated day,']), NOW)
    conflicts = value['quality']['currentConflictRecords']
    assert {row['title'] for row in conflicts} == {'Fixture first', 'Fixture second'}
    assert {row['sourceCsvRow'] for row in conflicts} == {1, 2}
    assert {row['originalChannelId'] for row in conflicts} == {'taipei-fm93-1'}
    assert all(row['sourceUrl'] == URL and row['sourceStart'].endswith('07:00:00+08:00') for row in conflicts)
    assert value['quality']['currentChannels'] == 0
    assert not any(p['startUtc'] <= NOW < p['endUtc'] for p in value['programmes'])


@pytest.mark.parametrize('row', [
    'FM,Holiday,070000,080000,Fixture,', 'FM,Sat、Sat,070000,080000,Fixture,',
    'XX,Sat,070000,080000,Fixture,', 'FM,Sat,076000,080000,Fixture,',
    'FM,Sat,250000,260000,Fixture,', 'FM,Sat,070000,060000,Fixture,',
    'FM,Sat,070000,080000,,'])
def test_invalid_rows_never_become_programmes(row):
    assert t.parse_schedule(envelope([row]), NOW)['programmes'] == []


@pytest.mark.parametrize('title', ['115年9月臺北廣播電臺中文節目表',
    '115年11月臺北廣播電臺中文節目表', '114年10月臺北廣播電臺中文節目表'])
def test_no_previous_month_or_future_month_extrapolation(title):
    with pytest.raises(EpgError, match='month_expired_or_future'):
        t.parse_schedule(envelope(['FM,Sat,070000,080000,Fixture,'], title), NOW)


def test_month_end_does_not_synthesize_following_month_dates():
    now = int(datetime(2026, 10, 31, 7, 30, tzinfo=t.ZONE).timestamp())
    value = t.parse_schedule(envelope(['FM,Sat、Sun,070000,080000,Fixture,']), now)
    assert all(p['sourceStart'].startswith('2026-10-') for p in value['programmes'])


def test_payload_checksum_and_schema_are_strict():
    value = json.loads(envelope(['FM,Sat,070000,080000,Fixture,']))
    value['csv'] += 'FM,Sat,080000,090000,Changed fixture,\n'
    with pytest.raises(EpgError, match='checksum_mismatch'):
        t.parse_schedule(json.dumps(value).encode(), NOW)


def test_resource_is_selected_by_exact_named_current_month_and_single_uuid():
    html = f'<table><tr><td>115年10月臺北廣播電臺中文節目表</td><td><a href="{URL}">下載</a></td></tr></table>'
    assert t.resource_for_month(html, datetime.fromtimestamp(NOW, t.ZONE).date())[0] == URL
    for bad in (html.replace('10月', '9月'), html.replace(URL, URL + '&url=https://127.0.0.1'), ''):
        with pytest.raises(EpgError): t.resource_for_month(bad, datetime.fromtimestamp(NOW, t.ZONE).date())


def test_fixed_query_boundary_rejects_arbitrary_hosts_paths_or_parameters():
    for url in ('https://127.0.0.1/', URL + '&extra=1', t.RESOURCE_PREFIX + '../private',
                URL.replace('data.taipei', 'evil.example.org')):
        with pytest.raises(EpgError, match='unreviewed_taipei_url'):
            t._read(url, 1024, None, 0, lambda: 0)


def test_registry_dispatch_is_fixed_to_two_reviewed_radio_services():
    source = next(s for s in registry() if s['id'] == t.SOURCE_ID)
    assert source['publicationAllowed'] is False
    parsed = parse_source(source, envelope(['FM,Sat,070000,080000,Fixture,']), NOW)
    assert set(parsed['channels']) == {'taipei-fm93-1', 'taipei-am1134'}
    assert parsed['identityContexts']['taipei-fm93-1']['countryCode'] == 'TW'


def test_monthly_credit_label_refresh_never_creates_or_reauthorizes_data(tmp_path):
    from epg_ingest import database
    import epg_store as store
    conn = database(tmp_path)
    store.migrate(conn)
    title = '115年10月臺北廣播電臺中文節目表'
    assert t.refresh_existing_credit(conn, title) is False
    assert conn.execute('SELECT count(*) FROM epg_data_grants').fetchone()[0] == 0
    source = next(s for s in registry() if s['id'] == t.SOURCE_ID)
    with conn:
        conn.execute('INSERT INTO source_health(id,url,configuration) VALUES(?,?,?)',
            (source['id'], source['url'], json.dumps(source)))
    store.approve_data_use(conn, source['id'], source_url=t.DATASET, evidence_url=t.DATASET,
        data_license=t.LICENSE, programme_data_permission=True,
        attribution=t.credit_for_title('115年9月臺北廣播電臺中文節目表'), now=NOW)
    before = tuple(conn.execute('SELECT * FROM epg_data_grants').fetchone())
    assert t.refresh_existing_credit(conn, title) is True
    assert t.refresh_existing_credit(conn, title) is False
    assert tuple(conn.execute('SELECT * FROM epg_data_grants').fetchone()) == before
    assert conn.execute('SELECT count(*) FROM epg_mapping_approvals').fetchone()[0] == 0
    conn.close()


@pytest.mark.parametrize('local, expected', [
    ((2026, 10, 17, 7, 30, 0), 21600),
    ((2026, 10, 31, 20, 30, 0), 12600),
    ((2026, 12, 31, 23, 59, 59), 1),
    ((2027, 1, 1, 0, 0, 0), 21600),
    ((2028, 2, 29, 23, 59, 0), 60),
])
def test_success_refresh_stops_at_explicit_month_boundary(local, expected):
    now = int(datetime(*local, tzinfo=t.ZONE).timestamp())
    assert t.success_refresh_delay(now, 21600) == expected


def test_month_boundary_success_is_checkpointed_without_early_refetch(tmp_path):
    from epg_ingest import database, probe_batch
    now = int(datetime(2026, 10, 31, 20, 30, tzinfo=t.ZONE).timestamp())
    boundary = int(datetime(2026, 11, 1, tzinfo=t.ZONE).timestamp())
    source = next(s for s in registry() if s['id'] == t.SOURCE_ID)
    body = envelope(['FM,Sat,200000,210000,Fixture current,',
        'FM,Sat,210000,220000,Fixture future,'])
    calls = []
    def fetch(_):
        calls.append(1)
        return body, {}
    result = probe_batch(tmp_path, [source], now, fetcher=fetch)
    row = next(r for r in result['sources'] if r['id'] == source['id'])
    assert row['state'] == 'healthy' and row['next_retry'] == boundary
    assert probe_batch(tmp_path, [source], now + 60, fetcher=fetch)['attemptedSources'] == 0
    assert calls == [1]
    def limited(_):
        raise EpgError('http_429', 86400)
    result = probe_batch(tmp_path, [source], boundary, fetcher=limited)
    row = next(r for r in result['sources'] if r['id'] == source['id'])
    assert row['state'] == 'failed' and row['next_retry'] >= boundary + 86400
    assert row['last_success'] == now
    assert row['content_sha256'] == hashlib.sha256(body).hexdigest()
    with closing(database(tmp_path)) as conn:
        tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        assert not {'epg_programmes', 'epg_data_grants'} & tables


def test_actual_current_conflict_with_valid_future_is_partial_not_fetch_failure(tmp_path):
    from epg_ingest import database, probe_batch
    source = next(s for s in registry() if s['id'] == t.SOURCE_ID)
    body = envelope(['FM,Sat,070000,080000,Fixture overlap A,',
        'FM,Sat,070000,080000,Fixture overlap B,',
        'FM,Sat,080000,090000,Fixture valid future,'])
    calls = []
    def fetch(_):
        calls.append(1)
        return body, {}
    result = probe_batch(tmp_path, [source], NOW, fetcher=fetch)
    row = next(r for r in result['sources'] if r['id'] == source['id'])
    quality = json.loads(row['last_good_quality'])
    assert row['state'] == 'partial' and row['last_error'] is None and row['failures'] == 0
    assert row['last_success'] == NOW and row['last_failure'] is None
    assert row['next_retry'] == NOW + source['refreshSeconds']
    assert quality['coverageStatus'] == 'current_slot_conflict_requires_review'
    assert quality['currentChannels'] == quality['currentAndFutureChannels'] == 0
    assert quality['futureChannels'] == 1 and len(quality['currentConflictRecords']) == 2
    assert probe_batch(tmp_path, [source], NOW + 60, fetcher=fetch)['attemptedSources'] == 0
    assert calls == [1] and not (tmp_path / 'payload-cache').exists()
    with closing(database(tmp_path)) as conn:
        assert conn.execute("SELECT count(*) FROM probe_audit WHERE state='partial'").fetchone()[0] == 1
        assert conn.execute('SELECT count(*) FROM source_identities').fetchone()[0] == 2


@pytest.mark.parametrize('rows, expected', [
    (['FM,Sat,060000,070000,Fixture expired,',
      'FM,Sat,070000,080000,Fixture overlap A,',
      'FM,Sat,070000,080000,Fixture overlap B,'], 'insufficient_current_future_coverage'),
    (['FM,Sat,070000,080000,Fixture overlap A,',
      'FM,Sat,070000,080000,Fixture overlap B,'], 'empty_or_expired_data'),
    (['FM,Sat,080000,090000,Fixture future without conflict evidence,'], 'insufficient_current_future_coverage'),
])
def test_partial_conflict_exception_never_accepts_empty_expired_or_unexplained_gap(tmp_path, rows, expected):
    from epg_ingest import probe_batch
    source = next(s for s in registry() if s['id'] == t.SOURCE_ID)
    now = int(datetime(2026, 10, 31, 7, 30, tzinfo=t.ZONE).timestamp())
    result = probe_batch(tmp_path, [source], now, fetcher=lambda _: (envelope(rows), {}))
    row = next(r for r in result['sources'] if r['id'] == source['id'])
    assert row['state'] == 'failed' and row['last_error'] == expected
    assert row['last_success'] is None and not (tmp_path / 'payload-cache').exists()


def test_upstream_retry_after_still_wins_after_a_partial_conflict(tmp_path):
    from epg_ingest import probe_batch
    source = next(s for s in registry() if s['id'] == t.SOURCE_ID)
    body = envelope(['FM,Sat,070000,080000,Fixture overlap A,',
        'FM,Sat,070000,080000,Fixture overlap B,',
        'FM,Sat,080000,090000,Fixture future,'])
    probe_batch(tmp_path, [source], NOW, fetcher=lambda _: (body, {}))
    due = NOW + source['refreshSeconds']
    def limited(_): raise EpgError('http_429', 86400)
    result = probe_batch(tmp_path, [source], due, fetcher=limited)
    row = next(r for r in result['sources'] if r['id'] == source['id'])
    assert row['state'] == 'failed' and row['next_retry'] >= due + 86400
    assert row['last_success'] == NOW and row['content_sha256'] == hashlib.sha256(body).hexdigest()
