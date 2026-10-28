"""Synthetic fixtures only; no production channel data, grants or publications."""
import json
import sqlite3

import pytest

from test_epg_store import conn, grant, ingest, licensed_grant, public_fetch, xml, NOW, CHANNEL, EVIDENCE, SOURCE
import epg_coverage as coverage
import epg_store as store
import epg_ingest as epg
import epg_discovery as discovery
import epg_schedule_worker as worker


def publish(conn, tmp_path):
    directory = tmp_path / 'public'
    manifest = store.publish(conn, directory, now=NOW, node_fetcher=public_fetch(directory, []))
    return directory, manifest


def test_missing_tables_do_not_migrate_or_write(tmp_path):
    connection = sqlite3.connect(tmp_path / 'empty.sqlite3')
    assert coverage.summarize(connection, NOW)['verifiedMappings'] == 0
    assert connection.execute('SELECT count(*) FROM sqlite_master').fetchone()[0] == 0
    assert not connection.in_transaction and connection.total_changes == 0
    connection.close()


def test_candidates_and_unpublished_rows_are_not_public_coverage(conn, tmp_path):
    assert coverage.summarize(conn, NOW, tmp_path)['currentAndFutureChannels'] == 0
    grant(conn)
    ingest(conn)
    result = coverage.summarize(conn, NOW, tmp_path)
    assert result['verifiedMappings'] == result['currentAndFutureChannels'] == 1
    assert result['publishedCurrentAndFutureChannels'] == 0 and result['publishedEpgVersion'] is None
    assert worker.coverage(conn, NOW)['currentAndFutureChannels'] == 1


def test_current_gap_separates_future_availability_from_current_coverage(conn, tmp_path):
    grant(conn)
    ingest(conn)
    with conn:
        conn.execute('DELETE FROM epg_programmes WHERE starts<=? AND stops>?', (NOW, NOW))
    result = coverage.summarize(conn, NOW, tmp_path / 'public')
    assert result['verifiedMappings'] == result['channelsWithFutureProgrammes'] == 1
    assert result['currentAndFutureChannels'] == result['publishedChannelsWithFutureProgrammes'] == 0
    directory, _ = publish(conn, tmp_path)
    result = coverage.summarize(conn, NOW, directory)
    assert result['publishedChannelsWithFutureProgrammes'] == 1
    assert result['currentAndFutureChannels'] == result['publishedCurrentAndFutureChannels'] == 0
    assert result['coverageError'] is None and result['publishedSnapshotVerifiedLocally']
    expired = coverage.summarize(conn, NOW + 7200, directory)
    assert expired['channelsWithFutureProgrammes'] == expired['publishedChannelsWithFutureProgrammes'] == 0


def test_active_snapshot_and_expiry_are_read_without_mutation(conn, tmp_path):
    grant(conn)
    ingest(conn)
    directory, manifest = publish(conn, tmp_path)
    changes = conn.total_changes
    result = coverage.summarize(conn, NOW, directory)
    assert result['publishedEpgVersion'] == manifest['version']
    assert result['publishedCurrentAndFutureChannels'] == 1
    assert result['publishedSnapshotVerifiedLocally'] and result['coverageError'] is None
    expired = coverage.summarize(conn, NOW + 7200, directory)
    assert expired['currentAndFutureChannels'] == expired['publishedCurrentAndFutureChannels'] == 0
    assert expired['publishedEpgVersion'] == manifest['version']
    assert conn.total_changes == changes and not conn.in_transaction


@pytest.mark.parametrize('changed', ['revoke', 'mapping', 'catalog', 'source', 'source_url'])
def test_revocation_and_identity_drift_remove_both_counts(conn, tmp_path, changed):
    grant(conn)
    ingest(conn)
    directory, _ = publish(conn, tmp_path)
    with conn:
        if changed == 'revoke':
            conn.execute('UPDATE epg_data_grants SET revoked=1')
        elif changed == 'mapping':
            conn.execute('UPDATE epg_mapping_approvals SET revoked=1')
        elif changed == 'catalog':
            conn.execute("UPDATE discovery_jobs SET identity_hash='changed'")
        elif changed == 'source':
            conn.execute("UPDATE source_identities SET names_json='[\"Different fixture\"]'")
        else:
            conn.execute("UPDATE source_health SET url='https://different.example.org/guide.xml'")
    result = coverage.summarize(conn, NOW, directory)
    assert result['verifiedMappings'] == result['currentAndFutureChannels'] == result['publishedCurrentAndFutureChannels'] == 0


@pytest.mark.parametrize('changed', ['evidence', 'confidence', 'grant'])
def test_changed_approval_requires_matching_programme_provenance(conn, tmp_path, changed):
    grant(conn)
    ingest(conn)
    directory, _ = publish(conn, tmp_path)
    with conn:
        if changed == 'evidence':
            conn.execute('UPDATE epg_mapping_approvals SET evidence=?',
                (json.dumps({**EVIDENCE, 'evidenceUrl': 'https://fixture.example.org/new-review'}),))
        elif changed == 'confidence':
            conn.execute('UPDATE epg_mapping_approvals SET confidence=0.97')
        else:
            conn.execute("UPDATE epg_data_grants SET evidence_url='https://fixture.example.org/new-permission'")
    result = coverage.summarize(conn, NOW, directory)
    assert result['verifiedMappings'] == 1
    assert result['currentAndFutureChannels'] == result['publishedCurrentAndFutureChannels'] == 0
    assert worker.coverage(conn, NOW)['currentAndFutureChannels'] == 0


def test_valid_last_published_version_survives_unpublished_programme_change(conn, tmp_path):
    grant(conn)
    ingest(conn)
    directory, manifest = publish(conn, tmp_path)
    epg.probe_batch(tmp_path / 'epg', [SOURCE], NOW + 900,
        lambda _: (xml(title='Next unactivated fixture version'), {}))
    ingest(conn, xml(title='Next unactivated fixture version'), now=NOW + 900)
    assert store.build_payload(conn, NOW + 900)['version'] != manifest['version']
    result = coverage.summarize(conn, NOW + 900, directory)
    assert result['currentAndFutureChannels'] == result['publishedCurrentAndFutureChannels'] == 1
    assert result['publishedEpgVersion'] == manifest['version']


@pytest.mark.parametrize('changed', ['missing', 'corrupt', 'symlink'])
def test_missing_or_corrupt_snapshot_never_counts_public_coverage(conn, tmp_path, changed):
    grant(conn)
    ingest(conn)
    directory, manifest = publish(conn, tmp_path)
    path = directory / 'snapshots' / (manifest['sha256'] + '.json.gz')
    if changed == 'missing':
        path.unlink()
    elif changed == 'corrupt':
        path.write_bytes(b'corrupt synthetic snapshot')
    else:
        moved = tmp_path / 'moved.gz'
        path.rename(moved)
        path.symlink_to(moved)
    result = coverage.summarize(conn, NOW, directory)
    assert result['currentAndFutureChannels'] == 1 and result['publishedCurrentAndFutureChannels'] == 0
    assert result['coverageError'] == 'coverage_evidence_invalid'


def test_credit_changes_withhold_old_public_snapshot(conn, tmp_path):
    licensed_grant(conn)
    ingest(conn)
    directory, _ = publish(conn, tmp_path)
    with conn:
        row = json.loads(conn.execute('SELECT metadata FROM epg_data_attributions').fetchone()[0])
        conn.execute('UPDATE epg_data_attributions SET metadata=?',
            (json.dumps({**row, 'modificationNotice': 'Updated synthetic notice'}),))
    result = coverage.summarize(conn, NOW, directory)
    assert result['currentAndFutureChannels'] == 1 and result['publishedCurrentAndFutureChannels'] == 0


def test_discovery_reads_actual_database_and_activation_receipt(conn, tmp_path, monkeypatch):
    grant(conn)
    ingest(conn)
    directory = tmp_path / 'epg/public'
    manifest = store.publish(conn, directory, now=NOW, node_fetcher=public_fetch(directory, []))
    monkeypatch.setattr(discovery, 'load_catalog', lambda _: ({'version': 'fixture-catalog'}, [CHANNEL]))
    result = discovery.run(tmp_path, now=NOW, runtime_seconds=0)
    assert result['verifiedCatalogMatches'] == result['currentAndFutureChannels'] == 1
    assert result['publishedCurrentAndFutureChannels'] == 1
    assert result['publishedEpgVersion'] == manifest['version']


def test_failed_node_verification_leaves_orphan_snapshot_unpublished(conn, tmp_path):
    grant(conn)
    ingest(conn)
    directory = tmp_path / 'public'
    with pytest.raises(epg.EpgError, match='public_snapshot_checksum_mismatch'):
        store.publish(conn, directory, now=NOW, node_fetcher=lambda _: b'wrong synthetic bytes')
    assert list((directory / 'snapshots').glob('*.json.gz'))
    result = coverage.summarize(conn, NOW, directory)
    assert result['currentAndFutureChannels'] == 1
    assert result['publishedEpgVersion'] is None and result['publishedCurrentAndFutureChannels'] == 0


def test_read_only_measurement_preserves_outer_uncommitted_writes(conn):
    grant(conn)
    conn.execute('UPDATE discovery_jobs SET priority=42')
    changes = conn.total_changes
    assert conn.in_transaction
    assert coverage.summarize(conn, NOW)['verifiedMappings'] == 1
    assert conn.in_transaction and conn.total_changes == changes
    assert conn.execute('SELECT priority FROM discovery_jobs').fetchone()[0] == 42
    conn.rollback()
    assert conn.execute('SELECT priority FROM discovery_jobs').fetchone()[0] != 42


def test_measurement_supports_readonly_database_connection(conn, tmp_path):
    grant(conn)
    ingest(conn)
    directory, _ = publish(conn, tmp_path)
    readonly = sqlite3.connect((tmp_path / 'epg/epg.sqlite3').resolve().as_uri() + '?mode=ro', uri=True)
    readonly.row_factory = sqlite3.Row
    try:
        result = coverage.summarize(readonly, NOW, directory)
        assert result['currentAndFutureChannels'] == result['publishedCurrentAndFutureChannels'] == 1
        assert readonly.total_changes == 0 and not readonly.in_transaction
    finally:
        readonly.close()
