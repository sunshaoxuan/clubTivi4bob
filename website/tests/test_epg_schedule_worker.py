"""Synthetic fixtures only. No real programme grants or public publications."""
import fcntl
import hashlib
import json
from pathlib import Path
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
