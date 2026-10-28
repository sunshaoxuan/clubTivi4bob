"""Synthetic fixtures only. No real programme grants or public publications."""
import fcntl
import hashlib
import json
from pathlib import Path
import sqlite3
import sys

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_ingest as epg
import epg_discovery as discovery
import epg_schedule_worker as worker
import epg_store as store

NOW = epg.timestamp('20261016080000 +0800')
SOURCE = {'id': 'licensed-fixture', 'url': 'https://fixture.example.org/guide.xml',
    'refreshSeconds': 900, 'publicationAllowed': False, 'dataLicense': {'status': 'fixture_only'}}
EVIDENCE = {'evidenceUrl': 'https://fixture.example.org/identity', 'countryCode': 'CN',
    'regionCode': None, 'sourceCountryCode': 'CN', 'sourceRegionCode': None,
    'sameChannelAndDelayVersion': True}


def body(label='first', count=1, stale=False):
    current = ('20261016070000 +0800', '20261016075900 +0800') if stale else (
        '20261016070000 +0800', '20261016090000 +0800')
    return ('<tv>' + ''.join(f'''<channel id="s{i}"><display-name>Fixture {i}</display-name></channel>
      <programme channel="s{i}" start="{current[0]}" stop="{current[1]}"><title>{label} {i}</title></programme>'''
      + ('' if stale else f'''<programme channel="s{i}" start="20261016090000 +0800" stop="20261016100000 +0800"><title>Next {i}</title></programme>''')
      for i in range(count)) + '</tv>').encode()


def setup(tmp_path, count=1, approve=True, cache=True):
    epg.probe_batch(tmp_path, [SOURCE], NOW, lambda _: (body(count=count), {}))
    conn = epg.database(tmp_path)
    discovery.sync_catalog(conn, {'version': 'fixture'}, [{'id': f'c{i}', 'name': f'Fixture {i}',
        'epgId': f's{i}', 'countryCode': 'CN', 'regionCode': None, 'routes': []} for i in range(count)], NOW)
    store.migrate(conn)
    if approve:
        store.approve_data_use(conn, SOURCE['id'], source_url=SOURCE['url'],
            evidence_url='https://fixture.example.org/data-permission', data_license='Synthetic fixture permission',
            programme_data_permission=True, now=NOW)
        for i in range(count):
            store.approve_mapping(conn, f'c{i}', SOURCE['id'], f's{i}', evidence=EVIDENCE, now=NOW)
    if cache:
        assert store.cache_validated_payload(conn, tmp_path, SOURCE['id'], body(count=count), NOW) == approve
    conn.close()


def titles(tmp_path):
    with epg.database(tmp_path) as conn:
        return [r[0] for r in conn.execute('SELECT title FROM epg_programmes ORDER BY channel_id,starts')]


def public_fetch(tmp_path, calls):
    def fetch(url):
        calls.append(url)
        return (tmp_path / 'public/snapshots' / url.rsplit('/', 1)[-1]).read_bytes()
    return fetch


def active(tmp_path):
    with epg.database(tmp_path) as conn:
        return store.active_manifest(conn)


def test_unapproved_diagnostics_never_cache_programmes_or_publish(tmp_path):
    setup(tmp_path, approve=False)
    assert not (tmp_path / 'payload-cache').exists()
    outcome = worker.run(tmp_path, now=NOW, node_fetcher=lambda _: pytest.fail('no HTTP'))
    assert outcome['selectedChannels'] == 0 and not outcome['publicationEnabled']
    assert not outcome['published'] and not (tmp_path / 'public').exists()
    assert titles(tmp_path) == []


def test_permission_without_exact_mapping_does_not_cache(tmp_path):
    setup(tmp_path, cache=False)
    with epg.database(tmp_path) as conn:
        conn.execute('DELETE FROM epg_mapping_approvals')
        conn.commit()
        assert not store.cache_validated_payload(conn, tmp_path, SOURCE['id'], body(), NOW)
    assert not (tmp_path / 'payload-cache').exists()


def test_bounded_batches_resume_and_same_payload_is_not_reparsed(tmp_path, monkeypatch):
    setup(tmp_path, count=6)
    first = worker.run(tmp_path, now=NOW)
    second = worker.run(tmp_path, now=NOW)
    assert (first['selectedChannels'], second['selectedChannels']) == (5, 1)
    assert len(titles(tmp_path)) == 12
    monkeypatch.setattr(store, 'ingest_batch', lambda *a, **k: pytest.fail('completed receipt must be skipped'))
    assert worker.run(tmp_path, now=NOW + 1)['selectedChannels'] == 0


def test_two_automatic_fixture_versions_use_one_validated_fetch_each(tmp_path):
    setup(tmp_path)
    calls = []
    first = worker.run(tmp_path, now=NOW, enable_publication=True, node_fetcher=public_fetch(tmp_path, calls))
    fetches = []
    def refresh(source):
        fetches.append(source['id'])
        return body('second'), {}
    epg.probe_batch(tmp_path, [SOURCE], NOW + 900, refresh)
    second = worker.run(tmp_path, now=NOW + 900, enable_publication=True, node_fetcher=public_fetch(tmp_path, calls))
    assert first['published'] and second['published'] and first['publishedVersion'] != second['publishedVersion']
    assert second['coverage'] == {'catalogChannels': 1, 'verifiedMappings': 1, 'currentAndFutureChannels': 1}
    assert fetches == [SOURCE['id']] and len(calls) == 4
    assert titles(tmp_path) == ['second 0', 'Next 0']
    cache = tmp_path / 'payload-cache/licensed-fixture.bin'
    assert cache.stat().st_mode & 0o777 == 0o600
    assert cache.parent.stat().st_mode & 0o777 == 0o700


def test_cache_corruption_backs_off_and_recovery_retains_last_good(tmp_path):
    setup(tmp_path)
    worker.run(tmp_path, now=NOW)
    epg.probe_batch(tmp_path, [SOURCE], NOW + 900, lambda _: (body('second'), {}))
    cache = tmp_path / 'payload-cache/licensed-fixture.bin'
    cache.write_bytes(b'corrupted fixture')
    failed = worker.run(tmp_path, now=NOW + 900)
    assert failed['error'] == 'payload_cache_checksum_mismatch' and failed['failedChannels'] == 1
    assert titles(tmp_path) == ['first 0', 'Next 0']
    cache.write_bytes(body('second'))
    assert worker.run(tmp_path, now=NOW + 959)['selectedChannels'] == 0
    assert worker.run(tmp_path, now=NOW + 960)['changedChannels'] == 1


def test_source_timeout_and_stale_http_success_keep_prior_cache(tmp_path):
    setup(tmp_path)
    worker.run(tmp_path, now=NOW)
    before = (tmp_path / 'payload-cache/licensed-fixture.bin').read_bytes()
    def timeout(_):
        raise TimeoutError('synthetic timeout')
    epg.probe_batch(tmp_path, [SOURCE], NOW + 900, timeout)
    epg.probe_batch(tmp_path, [SOURCE], NOW + 1000, lambda _: (body(stale=True), {}))
    assert (tmp_path / 'payload-cache/licensed-fixture.bin').read_bytes() == before
    assert worker.run(tmp_path, now=NOW + 1000)['selectedChannels'] == 0
    assert titles(tmp_path) == ['first 0', 'Next 0']
    epg.probe_batch(tmp_path, [SOURCE], NOW + 1200, lambda _: (body('recovered'), {}))
    assert worker.run(tmp_path, now=NOW + 1200)['changedChannels'] == 1


def test_killed_worker_lease_resumes_idempotently(tmp_path):
    setup(tmp_path)
    worker.run(tmp_path, now=NOW)
    with epg.database(tmp_path) as conn:
        conn.execute("UPDATE epg_ingestion_jobs SET state='processing',next_retry=?", (NOW + 120,))
    assert worker.run(tmp_path, now=NOW + 119)['selectedChannels'] == 0
    resumed = worker.run(tmp_path, now=NOW + 120)
    assert resumed['selectedChannels'] == 1 and resumed['changedChannels'] == 0
    assert len(titles(tmp_path)) == 2


def test_shared_validator_lock_prevents_duplicate_work(tmp_path):
    setup(tmp_path)
    with (tmp_path / 'worker.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        assert worker.run(tmp_path, now=NOW)['state'] == 'already_running'
    assert titles(tmp_path) == []


@pytest.mark.parametrize('change,error', [
    ('path', 'unsafe_payload_cache_path'), ('old', 'payload_cache_expired'),
    ('receipt', 'fetch_provenance_mismatch'), ('symlink', 'payload_cache_unavailable'),
])
def test_cache_path_age_and_receipt_guards(tmp_path, change, error):
    setup(tmp_path)
    at = NOW
    with epg.database(tmp_path) as conn:
        if change == 'path':
            conn.execute("UPDATE epg_source_payloads SET file_name='../outside.bin'")
        elif change == 'old':
            at += 1801
        elif change == 'receipt':
            conn.execute("UPDATE source_health SET content_sha256=?", ('0'*64,))
        elif change == 'symlink':
            cache = tmp_path / 'payload-cache/licensed-fixture.bin'
            cache.rename(tmp_path / 'outside.bin')
            cache.symlink_to(tmp_path / 'outside.bin')
    assert worker.run(tmp_path, now=at)['error'] == error
    assert titles(tmp_path) == []


def test_revoked_or_drifted_approval_never_ingests(tmp_path):
    setup(tmp_path)
    with epg.database(tmp_path) as conn:
        conn.execute('UPDATE epg_data_grants SET revoked=1')
    result = worker.run(tmp_path, now=NOW)
    assert result['selectedChannels'] == 0 and result['blockedApprovals'] == 1
    assert titles(tmp_path) == []


def test_coverage_expiry_is_reported_without_inventing_programmes(tmp_path):
    setup(tmp_path)
    assert worker.run(tmp_path, now=NOW)['coverage']['currentAndFutureChannels'] == 1
    expired = worker.run(tmp_path, now=NOW + 7200)
    assert expired['coverageDeclined'] and expired['coverage']['currentAndFutureChannels'] == 0
    assert len(titles(tmp_path)) == 2


def test_unchanged_completed_cache_is_monitored_and_gaps_are_idempotently_audited(tmp_path):
    setup(tmp_path)
    first = worker.run(tmp_path, now=NOW)
    assert first['channelCoverageMonitor']['states'] == {'covered': 1}
    gap = worker.run(tmp_path, now=NOW + 7200)
    assert gap['selectedChannels'] == 0
    assert gap['channelCoverageMonitor']['states'] == {'needs_schedule_review': 1}
    with epg.database(tmp_path) as conn:
        job = conn.execute('SELECT * FROM epg_coverage_gap_jobs').fetchone()
        evidence = json.loads(job['evidence'])
        assert job['reason'] == 'current_and_future_missing'
        assert not evidence['offAirConfirmed'] and evidence['upstreamRequests'] == 0
        assert conn.execute('SELECT count(*) FROM epg_coverage_gap_audit').fetchone()[0] == 2
    assert worker.run(tmp_path, now=NOW + 7201)['channelCoverageMonitor']['checkedChannels'] == 0
    worker.run(tmp_path, now=NOW + 7260)
    with epg.database(tmp_path) as conn:
        assert conn.execute('SELECT count(*) FROM epg_coverage_gap_audit').fetchone()[0] == 2
        assert conn.execute('SELECT count(*) FROM epg_programmes').fetchone()[0] == 2


def test_monitor_is_bounded_fair_and_does_not_refetch_or_mutate_programmes(tmp_path, monkeypatch):
    setup(tmp_path, count=6)
    assert worker.run(tmp_path, now=NOW)['channelCoverageMonitor']['checkedChannels'] == 5
    assert worker.run(tmp_path, now=NOW + 1)['channelCoverageMonitor']['checkedChannels'] == 1
    before = titles(tmp_path)
    monkeypatch.setattr(epg, 'fetch_source', lambda *a: pytest.fail('no source request'))
    monkeypatch.setattr(worker, 'read_payload', lambda *a: pytest.fail('no parse of covered cache'))
    assert worker.run(tmp_path, now=NOW + 60)['channelCoverageMonitor']['checkedChannels'] == 5
    assert titles(tmp_path) == before


def test_monitor_evidence_failure_does_not_claim_coverage_or_stop_worker(tmp_path):
    setup(tmp_path)
    worker.run(tmp_path, now=NOW)
    with epg.database(tmp_path) as conn:
        conn.execute('UPDATE epg_programmes SET provenance=?', ('[]',))
    result = worker.run(tmp_path, now=NOW + 60)
    assert result['channelCoverageMonitor']['states'] == {'needs_schedule_review': 1}
    with epg.database(tmp_path) as conn:
        evidence = json.loads(conn.execute('SELECT evidence FROM epg_coverage_gap_jobs').fetchone()[0])
        assert evidence['cacheError'] == 'coverage_monitor_evidence_invalid'


@pytest.mark.parametrize('table', ['epg_mapping_approvals', 'epg_data_grants'])
def test_monitor_revocation_closes_prior_covered_state_without_losing_audit(tmp_path, table):
    setup(tmp_path)
    worker.run(tmp_path, now=NOW)
    with epg.database(tmp_path) as conn:
        conn.execute('UPDATE ' + table + ' SET revoked=1')
    result = worker.run(tmp_path, now=NOW + 60)
    assert result['channelCoverageMonitor']['states'] == {'approval_requires_review': 1}
    with epg.database(tmp_path) as conn:
        evidence = json.loads(conn.execute('SELECT evidence FROM epg_coverage_gap_jobs').fetchone()[0])
        assert evidence['identityAndDataGrantVerified'] is False
        assert conn.execute('SELECT count(*) FROM epg_coverage_gap_audit').fetchone()[0] == 2
        assert conn.execute('SELECT count(*) FROM epg_programmes').fetchone()[0] == 2


def test_taipei_monitor_finds_live_raw_conflict_and_reuses_cache_between_locked_channels(tmp_path, monkeypatch):
    import epg_taipei as taipei
    import epg_coverage_gaps as monitor
    now = epg.timestamp('20261017073000 +0800')
    source = next(s for s in epg.registry() if s['id'] == taipei.SOURCE_ID)
    text = 'chanel,week,start_time,end_time,program,DJ\n' + ''.join(
        f'{band},Sat,070000,080000,Fixture current,\n'
        f'{band},Sat,080000,090000,Fixture conflicting A,\n'
        f'{band},Sat,080000,090000,Fixture conflicting B,\n'
        f'{band},Sat,090000,100000,Fixture next,\n' for band in ('FM', 'AM'))
    payload = json.dumps({'schemaVersion': 1, 'resourceTitle': '115年10月臺北廣播電臺中文節目表',
        'sourceUrl': taipei.RESOURCE_PREFIX + '00000000-0000-4000-8000-000000000001',
        'csv': text, 'csvSha256': hashlib.sha256(text.encode()).hexdigest()}).encode()
    epg.probe_batch(tmp_path, [source], now, lambda _: (payload, {}))
    with epg.database(tmp_path) as conn:
        discovery.sync_catalog(conn, {'version': 'fixture'}, [{'id': band, 'name': names[0],
            'epgId': sid, 'countryCode': 'TW', 'regionCode': None, 'routes': []}
            for band, (sid, names) in taipei.CHANNELS.items()], now)
        store.migrate(conn)
        store.approve_data_use(conn, source['id'], source_url=taipei.DATASET,
            evidence_url=taipei.DATASET, data_license=taipei.LICENSE, programme_data_permission=True,
            attribution=taipei.credit_for_title('115年10月臺北廣播電臺中文節目表'), now=now)
        for band, (sid, _) in taipei.CHANNELS.items():
            store.approve_mapping(conn, band, source['id'], sid,
                evidence={**EVIDENCE, 'countryCode': 'TW', 'sourceCountryCode': 'TW'}, now=now)
        assert store.cache_validated_payload(conn, tmp_path, source['id'], payload, now)
    worker.run(tmp_path, now=now)
    calls, original = [], monitor.parse_source
    def parse(*args):
        calls.append(args[0]['id'])
        return original(*args)
    monkeypatch.setattr(monitor, 'parse_source', parse)
    gap = worker.run(tmp_path, now=now + 1800)
    assert gap['selectedChannels'] == 0 and calls == [source['id']]
    assert gap['channelCoverageMonitor']['states'] == {'needs_schedule_review': 2}
    with epg.database(tmp_path) as conn:
        for row in conn.execute('SELECT * FROM epg_coverage_gap_jobs'):
            evidence = json.loads(row['evidence'])
            assert row['reason'] == 'current_source_slot_conflict'
            assert evidence['nextAcceptedStartUtc'] == now + 5400
            assert len(evidence['conflictingSourceRecords']) == 2
            assert all(p['originalChannelId'] == row['original_id'] for p in evidence['conflictingSourceRecords'])
            assert evidence['mappingLocked'] and not evidence['offAirConfirmed']
    assert worker.run(tmp_path, now=now + 5400)['channelCoverageMonitor']['states'] == {'covered': 2}


def test_relay_verification_failure_keeps_old_pointer_and_retries(tmp_path):
    setup(tmp_path)
    worker.run(tmp_path, now=NOW, enable_publication=True, node_fetcher=public_fetch(tmp_path, []))
    old = active(tmp_path)
    epg.probe_batch(tmp_path, [SOURCE], NOW + 900, lambda _: (body('second'), {}))
    calls = []
    def bad_relay(url):
        calls.append(url)
        return b'wrong' if 'cndrp.com' in url else public_fetch(tmp_path, [])(url)
    outcome = worker.run(tmp_path, now=NOW + 900, enable_publication=True, node_fetcher=bad_relay)
    assert not outcome['published'] and outcome['publicationError'] == 'public_snapshot_checksum_mismatch'
    assert active(tmp_path) == old
    worker.run(tmp_path, now=NOW + 959, enable_publication=True, node_fetcher=lambda _: pytest.fail('backoff'))
    recovered = worker.run(tmp_path, now=NOW + 960, enable_publication=True, node_fetcher=public_fetch(tmp_path, []))
    assert recovered['published'] and len(calls) == 2


@pytest.mark.parametrize('batch', [0, 6, True])
def test_invalid_batch_rejected_before_database_creation(tmp_path, batch):
    with pytest.raises(epg.EpgError, match='batch_size_limit'):
        worker.run(tmp_path, now=NOW, batch_size=batch)
    assert not (tmp_path / 'epg.sqlite3').exists()


@pytest.mark.parametrize('code', [sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED,
    sqlite3.SQLITE_BUSY | (1 << 8), sqlite3.SQLITE_BUSY | (2 << 8),
    sqlite3.SQLITE_LOCKED | (1 << 8)])
def test_database_busy_is_explicit_deferred_without_fabricated_coverage(tmp_path, monkeypatch, code):
    setup(tmp_path)
    worker.run(tmp_path, now=NOW)
    with epg.database(tmp_path) as conn:
        before = conn.execute("SELECT value FROM epg_checkpoints WHERE name='programme_ingestion'").fetchone()[0]
    error = sqlite3.OperationalError('synthetic contention')
    error.sqlite_errorcode = code
    def busy(*args):
        raise error
    monkeypatch.setattr(worker, '_run', busy)
    result = worker.run(tmp_path, now=NOW + 60)
    assert result['state'] == 'waiting_for_database'
    assert result['error'] == 'database_busy'
    assert result['retryOnNextTimer'] is True and result['retryNotBeforeUtc'] == NOW + 120
    assert result['lastCheckpointRetained'] is True
    assert result['partialWorkMayHaveCommitted'] is True
    assert 'coverage' not in result and 'published' not in result
    with epg.database(tmp_path) as conn:
        assert conn.execute("SELECT value FROM epg_checkpoints WHERE name='programme_ingestion'").fetchone()[0] == before
        assert conn.execute('SELECT count(*) FROM epg_programmes').fetchone()[0] == 2
    with (tmp_path / 'worker.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)


@pytest.mark.parametrize('code', [None, sqlite3.SQLITE_CORRUPT, sqlite3.SQLITE_FULL,
    sqlite3.SQLITE_IOERR, sqlite3.SQLITE_READONLY])
def test_non_contention_database_errors_still_fail(tmp_path, monkeypatch, code):
    error = sqlite3.OperationalError('database is locked')
    if code is not None:
        error.sqlite_errorcode = code
    def fail(*args):
        raise error
    monkeypatch.setattr(worker, '_run', fail)
    with pytest.raises(sqlite3.OperationalError):
        worker.run(tmp_path, now=NOW)


def test_actual_sqlite_exclusive_lock_defers_and_next_run_recovers(tmp_path, monkeypatch):
    setup(tmp_path)
    worker.run(tmp_path, now=NOW)
    with epg.database(tmp_path) as conn:
        before = conn.execute("SELECT value FROM epg_checkpoints WHERE name='programme_ingestion'").fetchone()[0]
    def short_database(directory):
        conn = sqlite3.connect(Path(directory) / 'epg.sqlite3', timeout=0.01)
        conn.row_factory = sqlite3.Row
        return conn
    monkeypatch.setattr(worker, 'database', short_database)
    holder = sqlite3.connect(tmp_path / 'epg.sqlite3')
    try:
        holder.execute('BEGIN EXCLUSIVE')
        result = worker.run(tmp_path, now=NOW + 60)
        assert result['state'] == 'waiting_for_database' and 'coverage' not in result
    finally:
        holder.rollback()
        holder.close()
    with epg.database(tmp_path) as conn:
        assert conn.execute("SELECT value FROM epg_checkpoints WHERE name='programme_ingestion'").fetchone()[0] == before
    recovered = worker.run(tmp_path, now=NOW + 120)
    assert recovered['selectedChannels'] == 0 and recovered['error'] is None
    assert recovered['coverage']['currentAndFutureChannels'] == 1
    assert titles(tmp_path) == ['first 0', 'Next 0']
