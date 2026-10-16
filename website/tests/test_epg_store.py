"""Synthetic fixture schedules only. Nothing here is a real public-channel EPG."""
import gzip
import json
from pathlib import Path
import sqlite3
import sys

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_catalog
import epg_discovery as discovery
import epg_ingest as epg
import epg_store as store

NOW = epg.timestamp('20261016080000 +0800')
SOURCE = {'id': 'fixture', 'url': 'https://fixture.example.org/guide.xml',
    'refreshSeconds': 900, 'publicationAllowed': False, 'dataLicense': {'status': 'fixture_only'}}
CHANNEL = {'id': 'fixture-channel', 'name': 'Synthetic Fixture', 'epgId': 'fixture',
    'countryCode': 'CN', 'regionCode': None, 'routes': []}
EVIDENCE = {'evidenceUrl': 'https://fixture.example.org/identity-review',
    'countryCode': 'CN', 'regionCode': None, 'sourceCountryCode': 'CN',
    'sourceRegionCode': None, 'sameChannelAndDelayVersion': True}


def xml(title='Fixture version one', stale=False):
    if stale:
        first = '<programme channel="fixture" start="20261016070000 +0800" stop="20261016075900 +0800"><title>Expired fixture</title></programme>'
    else:
        first = f'''<programme channel="fixture" start="20261016070000 +0800" stop="20261016090000 +0800"><title>{title}</title></programme>
          <programme channel="fixture" start="20261016090000 +0800" stop="20261016100000 +0800"><title>Next fixture</title></programme>'''
    return f'''<tv><channel id="fixture"><display-name>Synthetic Fixture</display-name></channel>
      <channel id="other"><display-name>Other Synthetic Fixture</display-name></channel>{first}
      <programme channel="other" start="20261016070000 +0800" stop="20261016090000 +0800"><title>Other current fixture</title></programme>
      <programme channel="other" start="20261016090000 +0800" stop="20261016100000 +0800"><title>Other next fixture</title></programme></tv>'''.encode()


@pytest.fixture
def conn(tmp_path):
    epg.probe_batch(tmp_path / 'epg', [SOURCE], NOW, lambda _: (xml(), {}))
    connection = epg.database(tmp_path / 'epg')
    discovery.sync_catalog(connection, {'version': 'fixture-catalog'}, [CHANNEL], NOW)
    store.migrate(connection)
    yield connection
    connection.close()


def grant(conn):
    store.approve_data_use(conn, 'fixture', source_url=SOURCE['url'],
        evidence_url='https://fixture.example.org/programme-data-permission',
        data_license='Synthetic test permission, never production data',
        programme_data_permission=True, now=NOW)
    store.approve_mapping(conn, CHANNEL['id'], 'fixture', 'fixture', evidence=EVIDENCE, now=NOW)


def ingest(conn, body=None, now=NOW):
    return store.ingest_batch(conn, 'fixture', body or xml(), [CHANNEL['id']], fetched_at=now, now=now)


def update_source(conn, tmp_path, body, now):
    # The same bounded fetch validator records the synthetic source receipt.
    epg.probe_batch(tmp_path / 'epg', [SOURCE], now, lambda _: (body, {}))


def public_fetch(directory, calls, manifest_exists=None):
    def fetch(url):
        calls.append(url)
        if manifest_exists is not None:
            with sqlite3.connect(directory.parent / 'epg/epg.sqlite3') as reader:
                assert (store.active_manifest(reader) is not None) == manifest_exists
        return (directory / 'snapshots' / url.rsplit('/', 1)[-1]).read_bytes()
    return fetch


def test_code_license_or_missing_permission_cannot_grant_publication(conn, tmp_path):
    with pytest.raises(epg.EpgError, match='programme_data_permission_required'):
        store.approve_data_use(conn, 'fixture', source_url=SOURCE['url'],
            evidence_url='https://fixture.example.org/code-license', data_license='MIT')
    with pytest.raises(epg.EpgError, match='approved_mapping_and_data_grant_required'):
        ingest(conn)
    with pytest.raises(epg.EpgError, match='no_publishable'):
        store.publish(conn, tmp_path / 'public', now=NOW)
    assert not (tmp_path / 'public/manifest.json').exists()
    assert conn.execute('SELECT count(*) FROM epg_programmes').fetchone()[0] == 0


ATTRIBUTION = {'sourceLabel': 'Synthetic licensed fixture',
    'attributionUrl': 'https://fixture.example.org/',
    'licenseUrl': 'https://creativecommons.org/licenses/by-sa/4.0/',
    'modificationNotice': 'Synthetic normalization fixture only; dates and fields standardized.',
    'shareAlikeRequired': True}


def licensed_grant(conn, attribution=ATTRIBUTION):
    store.approve_data_use(conn, 'fixture', source_url=SOURCE['url'],
        evidence_url='https://fixture.example.org/programme-data-permission',
        data_license='CC BY-SA 4.0', programme_data_permission=True,
        attribution=attribution, now=NOW)
    store.approve_mapping(conn, CHANNEL['id'], 'fixture', 'fixture', evidence=EVIDENCE, now=NOW)


@pytest.mark.parametrize('attribution', [None, {}, {**ATTRIBUTION, 'shareAlikeRequired': False},
    {**ATTRIBUTION, 'licenseUrl': 'https://wrong.example.org/'},
    {**ATTRIBUTION, 'modificationNotice': ''}])
def test_sharealike_data_grant_requires_explicit_credit_and_transformation_notice(conn, attribution):
    with pytest.raises(epg.EpgError, match='source_attribution_required'):
        licensed_grant(conn, attribution)
    assert conn.execute('SELECT count(*) FROM epg_data_grants').fetchone()[0] == 0


def test_attribution_survives_payload_build_and_is_bound_to_version(conn):
    licensed_grant(conn)
    ingest(conn)
    first = store.build_payload(conn, NOW)
    assert first['dataAttributions'] == [{'sourceId': 'fixture', **ATTRIBUTION}]
    assert first['programmes'][0]['provenance']['dataLicense'] == 'CC BY-SA 4.0'
    licensed_grant(conn, {**ATTRIBUTION, 'modificationNotice': 'Updated synthetic transformation statement'})
    second = store.build_payload(conn, NOW)
    assert second['version'] != first['version']
    with conn:
        conn.execute('DELETE FROM epg_data_attributions')
    with pytest.raises(epg.EpgError, match='no_publishable'):
        store.build_payload(conn, NOW)


@pytest.mark.parametrize('change', ['source-url', 'evidence-url', 'blank-license',
    'corrupt-credit', 'missing-credit-fields', 'unsafe-credit-url', 'sharealike',
    'json-license', 'json-source-credit'])
def test_current_data_use_review_gates_cache_ingestion_and_publication(conn, tmp_path, change):
    licensed_grant(conn)
    ingest(conn)
    directory = tmp_path / 'public'
    first = store.publish(conn, directory, now=NOW, node_fetcher=public_fetch(directory, []))
    before = [tuple(row) for row in conn.execute('SELECT * FROM epg_programmes')]
    with conn:
        if change == 'source-url':
            conn.execute("UPDATE source_health SET url='https://different.example.org/guide.xml'")
        elif change == 'evidence-url':
            conn.execute("UPDATE epg_data_grants SET evidence_url='http://127.0.0.1/private'")
        elif change == 'blank-license':
            conn.execute("UPDATE epg_data_grants SET data_license='  '")
        elif change in ('json-license', 'json-source-credit'):
            configuration = json.loads(conn.execute('SELECT configuration FROM source_health').fetchone()[0])
            conn.execute('UPDATE source_health SET configuration=?',
                (json.dumps({**configuration, 'format': 'tvmaze-json'}),))
            if change == 'json-license':
                conn.execute("UPDATE epg_data_grants SET data_license='Wrong synthetic JSON license'")
        else:
            metadata = dict(ATTRIBUTION)
            if change == 'corrupt-credit':
                metadata = None
            elif change == 'missing-credit-fields':
                metadata.pop('modificationNotice')
            elif change == 'unsafe-credit-url':
                metadata['attributionUrl'] = 'http://127.0.0.1/private'
            else:
                metadata['shareAlikeRequired'] = False
            conn.execute('UPDATE epg_data_attributions SET metadata=?',
                ('broken-json' if metadata is None else json.dumps(metadata),))
    assert store.reviewed_data_use(conn, 'fixture') is None
    assert not store.cache_validated_payload(conn, tmp_path / 'new-cache', 'fixture', xml(), NOW)
    assert not (tmp_path / 'new-cache/payload-cache').exists()
    with pytest.raises(epg.EpgError, match='current_data_use_review_required'):
        ingest(conn)
    with pytest.raises(epg.EpgError, match='no_publishable_current_future_data'):
        store.publish(conn, directory, now=NOW, node_fetcher=lambda _: pytest.fail('invalid rights must not make HTTP requests'))
    assert store.active_manifest(conn)['version'] == first['version']
    assert [tuple(row) for row in conn.execute('SELECT * FROM epg_programmes')] == before
    assert conn.execute('SELECT count(*) FROM epg_publication_audit').fetchone()[0] == 1
    with conn:
        conn.execute('UPDATE source_health SET url=?,configuration=?', (SOURCE['url'], json.dumps(SOURCE)))
    licensed_grant(conn)
    assert store.cache_validated_payload(conn, tmp_path / 'new-cache', 'fixture', xml(), NOW)
    assert ingest(conn)[0]['changed'] is False
    assert store.publish(conn, directory, now=NOW,
        node_fetcher=lambda _: pytest.fail('unchanged valid snapshot must not be fetched'))['changed'] is False


def test_changed_data_grant_rewrites_programme_provenance_before_publication(conn):
    licensed_grant(conn)
    ingest(conn)
    store.approve_data_use(conn, 'fixture', source_url=SOURCE['url'],
        evidence_url='https://fixture.example.org/new-programme-data-permission',
        data_license='New synthetic test permission', programme_data_permission=True, now=NOW + 1)
    assert ingest(conn)[0]['changed'] is True
    payload = store.build_payload(conn, NOW)
    assert payload['dataAttributions'] == []
    assert all(p['provenance']['dataLicense'] == 'New synthetic test permission' for p in payload['programmes'])
    assert all(p['provenance']['dataLicenseEvidenceUrl'].endswith('/new-programme-data-permission') for p in payload['programmes'])


@pytest.mark.parametrize('changed', ['license', 'evidence', 'mapping', 'confidence', 'corrupt', 'missing'])
def test_publication_blocks_stale_approval_provenance_until_reingestion(conn, tmp_path, changed):
    licensed_grant(conn)
    ingest(conn)
    directory = tmp_path / 'public'
    store.publish(conn, directory, now=NOW, node_fetcher=public_fetch(directory, []))
    first = store.active_manifest(conn)
    before_rows = [tuple(row) for row in conn.execute('SELECT * FROM epg_programmes')]
    with conn:
        if changed == 'license':
            # A legitimate replacement grant also updates its attribution scope.
            store.approve_data_use(conn, 'fixture', source_url=SOURCE['url'],
                evidence_url='https://fixture.example.org/programme-data-permission',
                data_license='Updated fixture permission', programme_data_permission=True, now=NOW + 1)
        elif changed == 'evidence':
            conn.execute("UPDATE epg_data_grants SET evidence_url='https://fixture.example.org/new-data-permission'")
        elif changed == 'mapping':
            conn.execute('UPDATE epg_mapping_approvals SET evidence=?',
                (json.dumps({**EVIDENCE, 'evidenceUrl': 'https://fixture.example.org/new-identity-review'}),))
        elif changed == 'confidence':
            conn.execute('UPDATE epg_mapping_approvals SET confidence=0.97')
        else:
            conn.execute('UPDATE epg_programmes SET provenance=? WHERE starts=(SELECT min(starts) FROM epg_programmes)',
                ('broken-json' if changed == 'corrupt' else '{}',))
    def must_not_fetch(url):
        raise AssertionError('Rejected provenance must not reach node verification')
    with pytest.raises(epg.EpgError, match='no_publishable_current_future_data'):
        store.publish(conn, directory, now=NOW, node_fetcher=must_not_fetch)
    assert store.active_manifest(conn) == first
    assert conn.execute('SELECT count(*) FROM epg_publication_audit').fetchone()[0] == 1
    if changed not in ('corrupt', 'missing'):
        assert [tuple(row) for row in conn.execute('SELECT * FROM epg_programmes')] == before_rows
        assert ingest(conn)[0]['changed'] is True
        assert store.build_payload(conn, NOW)['programmes']


def test_attribution_change_during_publication_keeps_manifest_inactive(conn, tmp_path):
    licensed_grant(conn)
    ingest(conn)
    def changed_attribution(url):
        raw = (tmp_path / 'public/snapshots' / url.rsplit('/', 1)[-1]).read_bytes()
        with conn:
            conn.execute('UPDATE epg_data_attributions SET approved_at=approved_at+1')
        return raw
    with pytest.raises(epg.EpgError, match='approval_changed_during_publication'):
        store.publish(conn, tmp_path / 'public', now=NOW, node_fetcher=changed_attribution)
    assert not (tmp_path / 'public/manifest.json').exists()


def test_live_clock_expiry_during_two_node_verification_cannot_activate(conn, tmp_path, monkeypatch):
    grant(conn)
    ingest(conn)
    clock = [NOW]
    monkeypatch.setattr(store.time, 'time', lambda: clock[0])
    calls = []
    def delayed_node(url):
        calls.append(url)
        raw = (tmp_path / 'public/snapshots' / url.rsplit('/', 1)[-1]).read_bytes()
        if len(calls) == 2:
            clock[0] = NOW + 7201
        return raw
    with pytest.raises(epg.EpgError, match='no_publishable_current_future_data'):
        store.publish(conn, tmp_path / 'public', node_fetcher=delayed_node)
    assert len(calls) == 2 and store.active_manifest(conn) is None
    assert conn.execute('SELECT count(*) FROM epg_publication_audit').fetchone()[0] == 0


@pytest.mark.parametrize('journal', ['delete', 'wal'])
@pytest.mark.parametrize('boundary,writer', [
    ('preflight', 'same-connection'), ('preflight', 'other-connection'),
    ('after-preflight', 'same-connection'), ('after-preflight', 'other-connection'),
    ('before-begin', 'other-connection')])
def test_publication_preflight_has_no_write_lock_and_detects_intervening_writes(
        conn, tmp_path, monkeypatch, journal, boundary, writer):
    grant(conn)
    ingest(conn)
    conn.execute('PRAGMA journal_mode=' + journal)
    path = conn.execute('PRAGMA database_list').fetchone()[2]
    external = sqlite3.connect(path, timeout=0)
    real_build = store.build_payload
    real_deadline = store._coverage_deadline
    scans, writes = [], []
    def change_data():
        target = conn if writer == 'same-connection' else external
        with target:
            target.execute("UPDATE epg_programmes SET title=title || ' changed'")
        writes.append(True)
    def preflight(connection, now):
        assert not connection.in_transaction
        payload = real_build(connection, now)
        scans.append(True)
        if len(scans) == 2 and boundary == 'preflight':
            change_data()
        return payload
    def before_begin(sql):
        if sql == 'BEGIN IMMEDIATE' and boundary == 'before-begin':
            change_data()
    def after_preflight(payload, now):
        deadline = real_deadline(payload, now)
        if boundary == 'after-preflight':
            change_data()
        return deadline
    monkeypatch.setattr(store, 'build_payload', preflight)
    monkeypatch.setattr(store, '_coverage_deadline', after_preflight)
    conn.set_trace_callback(before_begin)
    try:
        with pytest.raises(epg.EpgError, match='data_changed_during_publication'):
            store.publish(conn, tmp_path / 'public', now=NOW,
                node_fetcher=public_fetch(tmp_path / 'public', []))
    finally:
        conn.set_trace_callback(None)
        external.close()
    assert len(scans) == 2 and writes == [True]
    assert store.active_manifest(conn) is None
    assert conn.execute('SELECT count(*) FROM epg_publication_audit').fetchone()[0] == 0


@pytest.mark.parametrize('advance', [1, 3600, 3601, -1])
def test_activation_clock_boundary_is_checked_without_another_full_scan(
        conn, tmp_path, monkeypatch, advance):
    grant(conn)
    ingest(conn)
    clock = [NOW]
    monkeypatch.setattr(store.time, 'time', lambda: clock[0])
    real_deadline = store._coverage_deadline
    def delayed_deadline(payload, now):
        deadline = real_deadline(payload, now)
        clock[0] = NOW + advance
        return deadline
    monkeypatch.setattr(store, '_coverage_deadline', delayed_deadline)
    directory = tmp_path / 'public'
    if advance == 1:
        result = store.publish(conn, directory, node_fetcher=public_fetch(directory, []))
        assert result['changed'] is True
        assert result['generatedAt'] == '2026-10-16T00:00:01Z'
    else:
        error = 'data_changed_during_publication' if advance < 0 else 'no_publishable_current_future_data'
        with pytest.raises(epg.EpgError, match=error):
            store.publish(conn, directory, node_fetcher=public_fetch(directory, []))
        assert store.active_manifest(conn) is None


def test_context_and_locked_identity_guards(conn):
    with pytest.raises(epg.EpgError, match='source_context_mismatch'):
        store.approve_mapping(conn, CHANNEL['id'], 'fixture', 'fixture',
            evidence={**EVIDENCE, 'sourceCountryCode': 'US'}, now=NOW)
    grant(conn)
    discovery.sync_catalog(conn, {'version': 'changed-name'}, [{**CHANNEL, 'name': 'Other name'}], NOW + 1)
    with pytest.raises(epg.EpgError, match='mapping_locked'):
        store.approve_mapping(conn, CHANNEL['id'], 'fixture', 'fixture', evidence=EVIDENCE, now=NOW + 1)
    with pytest.raises(epg.EpgError, match='mapping_identity_drift'):
        ingest(conn)


@pytest.mark.parametrize('context', [
    {'countryCode': 'US'}, {'countryCode': 'CN', 'regionCode': 'other-region'},
    [], 'invalid-json',
])
def test_approval_checks_structured_source_country_and_region(conn, context):
    with conn:
        conn.execute('INSERT INTO source_identity_context VALUES(?,?,?,?)',
            ('fixture', 'fixture', context if context == 'invalid-json' else json.dumps(context), NOW))
    expected = 'invalid_source_identity_context' if not isinstance(context, dict) else 'source_context_mismatch'
    with pytest.raises(epg.EpgError, match=expected):
        grant(conn)
    assert conn.execute('SELECT count(*) FROM epg_mapping_approvals').fetchone()[0] == 0


@pytest.mark.parametrize('changed', [
    {'countryCode': 'US'}, {'regionCode': 'different-region'}, {'sourceTimezone': 'Asia/Tokyo'},
    {'originalNetworkId': 2}, None,
])
def test_source_context_drift_blocks_locked_mapping_ingestion_and_publication(conn, changed):
    context = {'countryCode': 'CN', 'regionCode': None, 'sourceTimezone': 'Asia/Shanghai', 'originalNetworkId': 1}
    with conn:
        conn.execute('INSERT INTO source_identity_context VALUES(?,?,?,?)',
            ('fixture', 'fixture', json.dumps(context), NOW))
    grant(conn)
    ingest(conn)
    before = [tuple(row) for row in conn.execute('SELECT * FROM epg_programmes')]
    with conn:
        if changed is None:
            conn.execute('DELETE FROM source_identity_context')
        else:
            conn.execute('UPDATE source_identity_context SET context_json=?', (json.dumps({**context, **changed}),))
    with pytest.raises(epg.EpgError, match='mapping_identity_drift'):
        ingest(conn)
    with pytest.raises(epg.EpgError, match='no_publishable_current_future_data'):
        store.build_payload(conn, NOW)
    assert [tuple(row) for row in conn.execute('SELECT * FROM epg_programmes')] == before
    with pytest.raises(epg.EpgError, match='mapping_locked|source_context_mismatch'):
        store.approve_mapping(conn, CHANNEL['id'], 'fixture', 'fixture', evidence=EVIDENCE, now=NOW + 1)


def test_batch_limit_fetch_receipt_and_source_url_guard(conn):
    grant(conn)
    with pytest.raises(epg.EpgError, match='batch_size_limit'):
        store.ingest_batch(conn, 'fixture', xml(), [CHANNEL['id']] * 6, fetched_at=NOW, now=NOW)
    with pytest.raises(epg.EpgError, match='fetch_provenance_mismatch'):
        store.ingest_batch(conn, 'fixture', xml('unverified bytes'), [CHANNEL['id']], fetched_at=NOW, now=NOW)
    with pytest.raises(epg.EpgError, match='source_url_mismatch'):
        store.approve_data_use(conn, 'fixture', source_url='https://different.example.org/guide.xml',
            evidence_url=EVIDENCE['evidenceUrl'], data_license='test', programme_data_permission=True)


def test_programme_provenance_and_identical_data_are_idempotent(conn):
    grant(conn)
    assert ingest(conn)[0]['changed'] is True
    before = [tuple(r) for r in conn.execute('SELECT * FROM epg_programmes ORDER BY starts')]
    assert ingest(conn)[0]['changed'] is False
    assert [tuple(r) for r in conn.execute('SELECT * FROM epg_programmes ORDER BY starts')] == before
    provenance = json.loads(before[0][-1])
    assert provenance['fetchedAtUtc'] == NOW
    assert provenance['sourceUrl'] == SOURCE['url']
    assert provenance['sourceTimezone'] == '+0800'
    assert provenance['sourceStart'] == '20261016070000 +0800'
    assert provenance['endBasis'] == 'explicit_stop'
    assert provenance['mappingEvidence'] == EVIDENCE


def test_stale_target_in_otherwise_healthy_feed_preserves_last_good(conn, tmp_path):
    grant(conn)
    ingest(conn)
    before = [tuple(r) for r in conn.execute('SELECT * FROM epg_programmes ORDER BY starts')]
    body = xml(stale=True)
    update_source(conn, tmp_path, body, NOW + 900)
    result = ingest(conn, body, NOW + 900)
    assert result[0]['retainedLastGood'] is True
    assert [tuple(r) for r in conn.execute('SELECT * FROM epg_programmes ORDER BY starts')] == before
    row = conn.execute('SELECT * FROM epg_schedule_state').fetchone()
    assert row['last_success'] == NOW and row['last_failure'] == NOW + 900
    assert row['last_error'] == 'insufficient_current_future_coverage'


def test_sql_failure_rolls_back_replacement_and_provenance(conn, tmp_path):
    grant(conn)
    ingest(conn)
    before = [tuple(r) for r in conn.execute('SELECT * FROM epg_programmes ORDER BY starts')]
    body = xml('Reject fixture')
    update_source(conn, tmp_path, body, NOW + 900)
    conn.execute("CREATE TRIGGER reject_fixture BEFORE INSERT ON epg_programmes WHEN NEW.title='Reject fixture' BEGIN SELECT RAISE(ABORT,'fixture rejection'); END")
    with pytest.raises(sqlite3.IntegrityError):
        ingest(conn, body, NOW + 900)
    assert [tuple(r) for r in conn.execute('SELECT * FROM epg_programmes ORDER BY starts')] == before


def test_two_consecutive_fixture_publications_and_unchanged_skip(conn, tmp_path):
    grant(conn)
    ingest(conn)
    directory, calls = tmp_path / 'public', []
    first = store.publish(conn, directory, now=NOW,
        node_fetcher=public_fetch(directory, calls, manifest_exists=False))
    assert len(calls) == 2 and first['changed'] is True
    old_snapshot = directory / 'snapshots' / (first['sha256'] + '.json.gz')
    assert old_snapshot.exists()
    second_body = xml('Fixture version two')
    update_source(conn, tmp_path, second_body, NOW + 900)
    ingest(conn, second_body, NOW + 900)
    second = store.publish(conn, directory, now=NOW + 900,
        node_fetcher=public_fetch(directory, calls, manifest_exists=True))
    assert len(calls) == 4 and second['version'] != first['version'] and old_snapshot.exists()
    def forbidden(_):
        raise AssertionError('Unchanged guide must not redownload snapshots')
    assert store.publish(conn, directory, now=NOW + 901, node_fetcher=forbidden)['changed'] is False
    assert conn.execute('SELECT count(*) FROM epg_publication_audit').fetchone()[0] == 2


@pytest.mark.parametrize('failure', ['timeout', 'checksum'])
def test_bad_or_unreachable_relay_keeps_previous_manifest(conn, tmp_path, failure):
    grant(conn)
    ingest(conn)
    directory, calls = tmp_path / 'public', []
    first = store.publish(conn, directory, now=NOW, node_fetcher=public_fetch(directory, calls))
    before = store.active_manifest(conn)
    body = xml('New fixture')
    update_source(conn, tmp_path, body, NOW + 900)
    ingest(conn, body, NOW + 900)
    def bad_relay(url):
        if url.startswith(store.NODES[1]):
            if failure == 'timeout':
                raise TimeoutError('must not leak upstream exception')
            return b'corrupted snapshot'
        return (directory / 'snapshots' / url.rsplit('/', 1)[-1]).read_bytes()
    with pytest.raises(epg.EpgError):
        store.publish(conn, directory, now=NOW + 900, node_fetcher=bad_relay)
    assert store.active_manifest(conn) == before
    assert before['sha256'] == first['sha256']
    recovered = store.publish(conn, directory, now=NOW + 901, node_fetcher=public_fetch(directory, []))
    assert recovered['changed'] is True and recovered['version'] != first['version']


def test_approval_revocation_during_node_verification_prevents_activation(conn, tmp_path):
    grant(conn)
    ingest(conn)
    directory = tmp_path / 'public'
    def revoke(url):
        with conn:
            conn.execute('UPDATE epg_data_grants SET revoked=1')
        return (directory / 'snapshots' / url.rsplit('/', 1)[-1]).read_bytes()
    with pytest.raises(epg.EpgError, match='approval_changed'):
        store.publish(conn, directory, now=NOW, node_fetcher=revoke)
    assert not (directory / 'manifest.json').exists()


def test_expired_schedules_never_create_a_false_success(conn, tmp_path):
    grant(conn)
    ingest(conn)
    with pytest.raises(epg.EpgError, match='no_publishable'):
        store.publish(conn, tmp_path / 'public', now=NOW + 3 * 3600)
    assert not (tmp_path / 'public/manifest.json').exists()


def test_readonly_version_api_and_immutable_content_cache_policy(conn, tmp_path, monkeypatch):
    directory = tmp_path / 'public'
    monkeypatch.setattr(epg_catalog, 'DIRECTORY', directory)
    monkeypatch.setattr(epg_catalog, 'DATABASE', Path(conn.execute('PRAGMA database_list').fetchone()[2]))
    app = FastAPI()
    app.include_router(epg_catalog.router)
    client = TestClient(app)
    initial = client.get('/api/v1/epg/manifest')
    assert initial.json()['version'] is None and 'no-store' in initial.headers['cache-control']
    grant(conn)
    ingest(conn)
    manifest = store.publish(conn, directory, now=NOW, node_fetcher=public_fetch(directory, []))
    response = client.get('/api/v1/epg/manifest')
    assert response.json()['version'] == manifest['version']
    assert response.headers['cache-control'] == 'no-store, max-age=0'
    assert client.get('/api/v1/epg/manifest', headers={'If-None-Match': response.headers['etag']}).status_code == 304
    snapshot = client.get(manifest['snapshotUrl'])
    assert snapshot.status_code == 200 and snapshot.headers['cache-control'].endswith('immutable')
    payload = json.loads(gzip.decompress(snapshot.content))
    assert payload['programmes'][0]['title'] == 'Fixture version one'
    assert client.get('/api/v1/epg/snapshots/' + 'a' * 64 + '.json.gz').status_code == 404


def test_relay_cache_configuration_never_caches_dynamic_epg_manifest():
    config = (Path(__file__).parents[1] / 'deploy/bobtv-resource-relay-cache.conf').read_text()
    assert '~^/bobtv/api/v1/epg/snapshots/ 1;' in config
    assert '/api/v1/epg/manifest' not in config


@pytest.mark.parametrize('failure', ['commit', 'audit-insert', 'pointer-update', 'snapshot-write'])
def test_atomic_activation_failures_preserve_committed_pointer_and_audit(conn, tmp_path, monkeypatch, failure):
    grant(conn)
    ingest(conn)
    directory = tmp_path / 'public'
    first = store.publish(conn, directory, now=NOW, node_fetcher=public_fetch(directory, []))
    old = store.active_manifest(conn)
    body = xml('Next atomic fixture')
    update_source(conn, tmp_path, body, NOW + 900)
    ingest(conn, body, NOW + 900)
    if failure == 'commit':
        conn.set_authorizer(lambda action, arg1, *args: sqlite3.SQLITE_DENY
            if action == sqlite3.SQLITE_TRANSACTION and arg1 == 'COMMIT' else sqlite3.SQLITE_OK)
    elif failure == 'audit-insert':
        conn.execute("CREATE TRIGGER reject_publication BEFORE INSERT ON epg_publication_audit BEGIN SELECT RAISE(ABORT,'fixture'); END")
    elif failure == 'pointer-update':
        conn.execute("CREATE TRIGGER reject_pointer BEFORE UPDATE ON epg_publication_state BEGIN SELECT RAISE(ABORT,'fixture'); END")
    else:
        def broken_write(*args):
            raise OSError('synthetic disk failure')
        monkeypatch.setattr(store, '_atomic_write', broken_write)
    try:
        with pytest.raises((sqlite3.Error, OSError)):
            store.publish(conn, directory, now=NOW + 900, node_fetcher=public_fetch(directory, []))
    finally:
        conn.set_authorizer(None)
    assert store.active_manifest(conn) == old
    assert old['version'] == first['version']
    assert conn.execute('SELECT count(*) FROM epg_publication_audit').fetchone()[0] == 1
    assert conn.execute('SELECT count(*) FROM epg_publication_manifests').fetchone()[0] == 1
    assert not (directory / 'manifest.json').exists()


def test_other_reader_sees_old_state_until_audit_receipt_and_pointer_commit(conn, tmp_path):
    grant(conn)
    ingest(conn)
    directory = tmp_path / 'public'
    first = store.publish(conn, directory, now=NOW, node_fetcher=public_fetch(directory, []))
    body = xml('Transaction fixture two')
    update_source(conn, tmp_path, body, NOW + 900)
    ingest(conn, body, NOW + 900)
    seen = []
    database_path = conn.execute('PRAGMA database_list').fetchone()[2]
    def before_commit(sql):
        if sql.strip().upper() == 'COMMIT':
            reader = sqlite3.connect(database_path)
            try:
                seen.append(store.active_manifest(reader)['version'])
                assert reader.execute('SELECT count(*) FROM epg_publication_audit').fetchone()[0] == 1
            finally:
                reader.close()
    conn.set_trace_callback(before_commit)
    second = store.publish(conn, directory, now=NOW + 900, node_fetcher=public_fetch(directory, []))
    conn.set_trace_callback(None)
    assert seen == [first['version']]
    assert store.active_manifest(conn)['version'] == second['version']
    assert conn.execute('SELECT count(*) FROM epg_publication_audit').fetchone()[0] == 2


def test_legacy_file_manifest_cannot_activate_an_uncommitted_version(conn, tmp_path, monkeypatch):
    directory = tmp_path / 'public'
    directory.mkdir()
    (directory / 'manifest.json').write_text(json.dumps({'version': 'forged-file-only'}))
    monkeypatch.setattr(epg_catalog, 'DIRECTORY', directory)
    monkeypatch.setattr(epg_catalog, 'DATABASE', Path(conn.execute('PRAGMA database_list').fetchone()[2]))
    app = FastAPI()
    app.include_router(epg_catalog.router)
    assert TestClient(app).get('/api/v1/epg/manifest').json()['version'] is None


@pytest.mark.parametrize('failure', ['missing-snapshot', 'corrupt-snapshot', 'broken-audit', 'invalid-json'])
def test_api_fails_closed_on_broken_committed_receipt_or_content(conn, tmp_path, monkeypatch, failure):
    grant(conn)
    ingest(conn)
    directory = tmp_path / 'public'
    manifest = store.publish(conn, directory, now=NOW, node_fetcher=public_fetch(directory, []))
    snapshot = directory / 'snapshots' / (manifest['sha256'] + '.json.gz')
    if failure == 'missing-snapshot':
        snapshot.rename(snapshot.with_suffix('.saved'))
    elif failure == 'corrupt-snapshot':
        snapshot.write_bytes(b'broken')
    elif failure == 'broken-audit':
        with conn:
            conn.execute('DELETE FROM epg_publication_audit')
    else:
        with conn:
            conn.execute("UPDATE epg_publication_manifests SET manifest='{}'")
    monkeypatch.setattr(epg_catalog, 'DIRECTORY', directory)
    monkeypatch.setattr(epg_catalog, 'DATABASE', Path(conn.execute('PRAGMA database_list').fetchone()[2]))
    app = FastAPI()
    app.include_router(epg_catalog.router)
    response = TestClient(app).get('/api/v1/epg/manifest')
    assert response.status_code == 503
    assert response.json() == {'error': 'epg_publication_unavailable'}
    assert 'no-store' in response.headers['cache-control']


def test_main_api_registers_epg_readonly_route_without_creating_a_database(tmp_path, monkeypatch):
    import app
    missing = tmp_path / 'no-database.sqlite3'
    monkeypatch.setattr(epg_catalog, 'DATABASE', missing)
    result = TestClient(app.app).get('/api/v1/epg/manifest')
    assert result.status_code == 200 and result.json()['version'] is None
    assert not missing.exists()


def test_standalone_api_is_readonly_and_returns_no_published_data(tmp_path, monkeypatch):
    import epg_api
    missing = tmp_path / 'no-database.sqlite3'
    monkeypatch.setattr(epg_catalog, 'DATABASE', missing)
    client = TestClient(epg_api.app)
    assert client.get('/api/v1/epg/manifest').json() == {'schemaVersion': 1, 'version': None, 'channelCount': 0}
    assert client.post('/api/v1/epg/manifest', json={'version': 'fixture'}).status_code == 405
    assert client.get('/docs').status_code == 404 and not missing.exists()
