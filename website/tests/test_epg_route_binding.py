"""Synthetic routes only; no real mappings or programmes are approved."""
import hashlib
import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parents[1]))

import pytest
import epg_route_binding as routes
import epg_store as store
import epg_discovery as discovery
from test_epg_store import conn, grant, ingest, CHANNEL, EVIDENCE, NOW
from test_epg_store import public_fetch
import epg_coverage as coverage

URL = 'https://fixture.example.org/official.m3u8'
SCOPE = [{'routeId': 'route-official', 'urlSha256': hashlib.sha256(URL.encode()).hexdigest()}]
CATALOGUE = {**CHANNEL, 'routes': [{'id': 'route-official', 'url': URL},
    {'id': 'route-unknown', 'url': 'https://relay.example.org/unknown.m3u8'}]}


def scoped(conn, monkeypatch):
    monkeypatch.setattr(discovery, 'load_catalog', lambda _: ({}, [CATALOGUE]))
    grant(conn)
    # Simulate an explicit fresh review on a new, previously unlocked fixture.
    with conn:
        conn.execute('DELETE FROM epg_mapping_approvals')
    store.approve_mapping(conn, CHANNEL['id'], 'fixture', 'fixture', evidence={
        **EVIDENCE, 'routeScope': SCOPE, 'routeScopeExplicitlyReviewed': True}, now=NOW)


def test_only_reviewed_route_and_exact_address_are_accepted():
    assert routes.validate_scope(SCOPE, CATALOGUE) == SCOPE
    for scope in ([], SCOPE * 2, [{'routeId': 'route-unknown', 'urlSha256': SCOPE[0]['urlSha256']}],
                  [{'routeId': 'route-official', 'urlSha256': '0' * 64}]):
        with pytest.raises(Exception):
            routes.validate_scope(scope, CATALOGUE)


def test_public_scope_is_legacy_safe_and_preserves_parent(conn, monkeypatch):
    scoped(conn, monkeypatch)
    ingest(conn)
    before = [tuple(r) for r in conn.execute('SELECT * FROM epg_programmes')]
    payload = store.build_payload(conn, NOW)
    identity = payload['channels'][0]
    assert identity['id'].startswith('route-epg-')
    assert identity['id'] != CHANNEL['id']
    assert identity['routeBinding']['catalogChannelId'] == CHANNEL['id']
    assert identity['routeBinding']['routes'] == SCOPE
    assert identity['catalogIdentityHash'] == discovery.fingerprint({k: identity.get(k)
        for k in ('id', 'name', 'epgId', 'countryCode', 'regionCode')})
    assert {p['channelId'] for p in payload['programmes']} == {identity['id']}
    assert before == [tuple(r) for r in conn.execute('SELECT * FROM epg_programmes')]


def test_route_drift_blocks_new_ingest_and_publish_without_deleting_cache(conn, monkeypatch):
    scoped(conn, monkeypatch)
    ingest(conn)
    before = [tuple(r) for r in conn.execute('SELECT * FROM epg_programmes')]
    monkeypatch.setattr(discovery, 'load_catalog', lambda _: ({}, [{**CATALOGUE, 'routes': []}]))
    with pytest.raises(Exception, match='epg_route_identity_drift'):
        ingest(conn)
    with pytest.raises(Exception, match='no_publishable'):
        store.build_payload(conn, NOW)
    assert before == [tuple(r) for r in conn.execute('SELECT * FROM epg_programmes')]


def test_locked_scope_cannot_be_widened_or_removed(conn, monkeypatch):
    scoped(conn, monkeypatch)
    for evidence in (EVIDENCE, {**EVIDENCE, 'routeScope': SCOPE}):
        with pytest.raises(Exception, match='mapping_locked|epg_route_review_required'):
            store.approve_mapping(conn, CHANNEL['id'], 'fixture', 'fixture', evidence=evidence, now=NOW)


def test_scoped_snapshot_is_counted_as_one_covered_catalogue_channel(conn, monkeypatch, tmp_path):
    scoped(conn, monkeypatch)
    ingest(conn)
    directory = tmp_path / 'public'
    store.publish(conn, directory, now=NOW, node_fetcher=public_fetch(directory, []))
    result = coverage.summarize(conn, NOW, directory)
    assert result['coverageError'] is None
    assert result['verifiedMappings'] == result['currentAndFutureChannels'] == 1
    assert result['publishedCurrentAndFutureChannels'] == 1


def test_two_scoped_versions_keep_route_scope_and_rollback_bad_relay(conn, monkeypatch, tmp_path):
    from test_epg_store import update_source, xml
    scoped(conn, monkeypatch)
    ingest(conn)
    directory = tmp_path / 'public'
    first = store.publish(conn, directory, now=NOW, node_fetcher=public_fetch(directory, []))
    body = xml('Updated synthetic scoped programme')
    update_source(conn, tmp_path, body, NOW + 901)
    ingest(conn, body, NOW + 901)
    def broken(_):
        return b'corrupt fixture'
    with pytest.raises(Exception, match='public_snapshot_checksum_mismatch'):
        store.publish(conn, directory, now=NOW + 901, node_fetcher=broken)
    assert store.active_manifest(conn)['version'] == first['version']
    second = store.publish(conn, directory, now=NOW + 901, node_fetcher=public_fetch(directory, []))
    assert first['version'] != second['version']
    assert store.build_payload(conn, NOW + 901)['channels'][0]['routeBinding']['routes'] == SCOPE
