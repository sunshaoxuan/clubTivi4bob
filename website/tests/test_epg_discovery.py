import gzip
import hashlib
import json
import os
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_discovery as discovery
import epg_ingest as epg

NOW = epg.timestamp('20261016080000 +0800')
SOURCE = {'id': 'test', 'url': 'https://epg.example.org/guide.xml',
          'redirectUrls': [], 'refreshSeconds': 21600,
          'publicationAllowed': False, 'dataLicense': {'status': 'unverified'}}


def xml(identity='CCTV5+', name='CCTV5+', title='Current'):
    return f'''<tv><channel id="{identity}"><display-name>{name}</display-name></channel>
    <programme channel="{identity}" start="20261016070000 +0800" stop="20261016090000 +0800"><title>{title}</title></programme>
    <programme channel="{identity}" start="20261016090000 +0800" stop="20261016100000 +0800"><title>Next</title></programme></tv>'''.encode()


def channel(identity='one', name='CCTV-5+', epg_id='CCTV5+'):
    return {'id': identity, 'name': name, 'epgId': epg_id, 'countryCode': 'CN',
            'regionCode': None, 'routes': [{'lastPlayableAt': '2026-10-16T00:00:00Z'}]}


def seeded(tmp_path, sources=None):
    sources = sources or [SOURCE]
    for _ in sources:
        epg.probe_batch(tmp_path / 'epg', sources, NOW, lambda _: (xml(), {}))
    conn = epg.database(tmp_path / 'epg')
    discovery.migrate(conn)
    return conn


def catalog(tmp_path, channels, version='one'):
    base = tmp_path / 'channel-catalog'
    (base / 'snapshots').mkdir(parents=True, exist_ok=True)
    raw = gzip.compress(json.dumps({'version': version, 'channels': channels}).encode())
    sha = hashlib.sha256(raw).hexdigest()
    (base / 'snapshots' / (sha + '.json.gz')).write_bytes(raw)
    manifest = {'version': version, 'sha256': sha, 'channelCount': len(channels)}
    (base / 'manifest.json').write_text(json.dumps(manifest))
    return manifest


def test_canonical_keeps_number_plus_region_and_delay_variants():
    assert discovery.canonical('ＣＣＴＶ-05+') == 'cctv5+'
    assert discovery.canonical('CCTV5') != discovery.canonical('CCTV5+')
    assert discovery.canonical('BBC One') != discovery.canonical('BBC One +1')
    assert discovery.canonical('ABC New York') != discovery.canonical('ABC Chicago')
    assert discovery.canonical('CCTV1 4K') != discovery.canonical('CCTV1')


def test_probe_persists_identity_metadata_without_programme_titles(tmp_path):
    with seeded(tmp_path) as conn:
        row = dict(conn.execute('SELECT * FROM source_identities').fetchone())
        assert row['original_id'] == 'CCTV5+'
        assert row['fetched_at'] == NOW and row['origin'] == 'server_fetch'
        assert row['content_sha256'] == hashlib.sha256(xml()).hexdigest()
        assert 'Current' not in json.dumps(row)


def test_cache_seed_preserves_fetch_time_does_not_contact_upstream_and_is_idempotent(tmp_path):
    directory, cache = tmp_path / 'epg', tmp_path / 'cache'
    cache.mkdir()
    path = cache / hashlib.sha256(SOURCE['url'].encode()).hexdigest()
    path.write_bytes(xml())
    os.utime(path, (NOW - 300, NOW - 300))
    assert epg.seed_cached_identities(directory, [SOURCE], cache, NOW) == ['test']
    with epg.database(directory) as conn:
        row = conn.execute('SELECT * FROM source_identities').fetchone()
        assert row['fetched_at'] == NOW - 300 and row['observed_at'] == NOW
        assert row['origin'] == 'existing_egress_cache'
        assert conn.execute('SELECT count(*) FROM source_health').fetchone()[0] == 0
    assert epg.seed_cached_identities(directory, [SOURCE], cache, NOW + 1) == []
    with epg.database(directory) as conn:
        assert conn.execute('SELECT count(*) FROM probe_audit').fetchone()[0] == 1


def test_cache_seed_rejects_old_or_invalid_cache(tmp_path):
    cache = tmp_path / 'cache'
    cache.mkdir()
    path = cache / hashlib.sha256(SOURCE['url'].encode()).hexdigest()
    path.write_bytes(xml())
    os.utime(path, (NOW - 86401, NOW - 86401))
    assert epg.seed_cached_identities(tmp_path / 'epg', [SOURCE], cache, NOW) == []
    path.write_bytes(b'<html/>')
    os.utime(path, (NOW, NOW))
    assert epg.seed_cached_identities(tmp_path / 'epg', [SOURCE], cache, NOW) == []


def test_exact_id_and_name_are_review_candidates_never_auto_applied(tmp_path):
    with seeded(tmp_path) as conn:
        _, ids, names = discovery.source_index(conn, NOW)
        result = discovery.candidates_for(channel(), ids, names)
        assert len(result) == 1 and result[0]['identityEvidence'] == 'exact_id_and_name'
        assert not result[0]['automaticallyApplied']
        assert not result[0]['contextVerified'] and not result[0]['programmeDataRightsVerified']
        assert result[0]['sourceUrl'] == SOURCE['url']


@pytest.mark.parametrize('item', [
    channel(name='CCTV5', epg_id='CCTV5'),
    channel(name='CCTV5', epg_id='CCTV5+'),
    channel(name='CCTV5+', epg_id='CCTV5'),
    channel(name='CCTV5+ +1', epg_id='CCTV5+'),
    channel(name='CCTV', epg_id=None),
])
def test_partial_name_number_conflict_and_delay_never_share_proposal(tmp_path, item):
    with seeded(tmp_path) as conn:
        _, ids, names = discovery.source_index(conn, NOW)
        assert discovery.candidates_for(item, ids, names) == []


def test_country_region_are_preserved_and_full_name_only_requires_review(tmp_path):
    with seeded(tmp_path) as conn:
        _, ids, names = discovery.source_index(conn, NOW)
        result = discovery.candidates_for({**channel(epg_id=None), 'countryCode': 'HK', 'regionCode': 'HK'}, ids, names)
        assert result[0]['identityEvidence'] == 'exact_full_name_only'
        assert result[0]['countryCode'] == 'HK' and result[0]['regionCode'] == 'HK'
        assert not result[0]['contextVerified']


def test_resume_batches_are_max_five_and_unchanged_review_is_not_repeated(tmp_path):
    with seeded(tmp_path) as conn:
        items = [channel(str(i)) for i in range(12)]
        discovery.sync_catalog(conn, {'version': 'a'}, items, NOW)
        generation, ids, names = discovery.source_index(conn, NOW)
        assert [discovery.process_batch(conn, generation, ids, names, NOW) for _ in range(4)] == [5, 5, 2, 0]
        assert conn.execute('SELECT count(*) FROM mapping_review_audit').fetchone()[0] == 12
        discovery.sync_catalog(conn, {'version': 'b'}, items, NOW + 300)
        assert discovery.process_batch(conn, generation, ids, names, NOW + 300) == 0
        assert conn.execute('SELECT count(*) FROM mapping_review_audit').fetchone()[0] == 12


def test_identity_change_requeues_only_changed_target_and_keeps_old_audit(tmp_path):
    with seeded(tmp_path) as conn:
        discovery.sync_catalog(conn, {'version': 'a'}, [channel('a'), channel('b')], NOW)
        generation, ids, names = discovery.source_index(conn, NOW)
        assert discovery.process_batch(conn, generation, ids, names, NOW) == 2
        discovery.sync_catalog(conn, {'version': 'b'}, [channel('a', 'CCTV5', 'CCTV5'), channel('b')], NOW + 1)
        assert discovery.process_batch(conn, generation, ids, names, NOW + 1) == 1
        assert conn.execute('SELECT count(*) FROM mapping_review_audit').fetchone()[0] == 3
        discovery.sync_catalog(conn, {'version': 'c'}, [channel('b')], NOW + 2)
        assert conn.execute('SELECT count(*) FROM discovery_jobs WHERE active=1').fetchone()[0] == 1
        assert conn.execute('SELECT count(*) FROM mapping_review_audit').fetchone()[0] == 3


def test_programme_update_does_not_invalidate_identity_generation(tmp_path):
    with seeded(tmp_path) as conn:
        generation, _, _ = discovery.source_index(conn, NOW)
    epg.probe_batch(tmp_path / 'epg', [SOURCE], NOW + 21600, lambda _: (xml(title='Different'), {}))
    # At the original check instant the identity is unchanged despite new bytes.
    with epg.database(tmp_path / 'epg') as conn:
        assert discovery.source_index(conn, NOW)[0] == generation


def test_programme_window_expiry_does_not_restart_unchanged_identity_review(tmp_path):
    with seeded(tmp_path) as conn:
        discovery.sync_catalog(conn, {'version': 'a'}, [channel()], NOW)
        generation, ids, names = discovery.source_index(conn, NOW)
        assert discovery.process_batch(conn, generation, ids, names, NOW) == 1
        audit_count = conn.execute('SELECT count(*) FROM mapping_review_audit').fetchone()[0]
        # Both synthetic programmes have ended, while the fetched identity
        # metadata is still within its existing bounded freshness allowance.
        later = NOW + 2 * 3600 + 1
        following, ids, names = discovery.source_index(conn, later)
        assert following == generation
        proposals = discovery.candidates_for(channel(), ids, names)
        assert len(proposals) == 1
        assert not proposals[0]['contextVerified']
        assert not proposals[0]['automaticallyApplied']
        assert discovery.process_batch(conn, following, ids, names, later) == 0
        assert conn.execute('SELECT count(*) FROM mapping_review_audit').fetchone()[0] == audit_count


def test_identity_metadata_after_programme_end_never_becomes_programme_coverage(tmp_path):
    import epg_store as store
    from epg_coverage import summarize
    with seeded(tmp_path) as conn:
        store.migrate(conn)
        discovery.sync_catalog(conn, {'version': 'a'}, [channel()], NOW)
        later = NOW + 2 * 3600 + 1
        generation, ids, names = discovery.source_index(conn, later)
        assert discovery.candidates_for(channel(), ids, names)
        assert discovery.process_batch(conn, generation, ids, names, later) == 1
        measured = summarize(conn, later)
        assert measured['verifiedMappings'] == 0
        assert measured['currentAndFutureChannels'] == 0
        assert conn.execute('SELECT count(*) FROM epg_programmes').fetchone()[0] == 0
        with pytest.raises(epg.EpgError, match='no_publishable_current_future_data'):
            store.build_payload(conn, later)


@pytest.mark.parametrize('unavailable', ['stale-fetch', 'persistent-failure', 'superseded'])
def test_programme_independent_identity_generation_still_excludes_unavailable_sources(tmp_path, unavailable):
    with seeded(tmp_path) as conn:
        before, _, _ = discovery.source_index(conn, NOW)
        later = NOW + 2 * 3600 + 1
        if unavailable == 'stale-fetch':
            later = NOW + SOURCE['refreshSeconds'] * 2 + 1
        else:
            with conn:
                if unavailable == 'persistent-failure':
                    conn.execute("UPDATE source_health SET failures=3,state='failed'")
                else:
                    conn.execute("UPDATE source_health SET state='superseded'")
        following, ids, names = discovery.source_index(conn, later)
        assert following != before
        assert discovery.candidates_for(channel(), ids, names) == []
        assert conn.execute('SELECT count(*) FROM source_identities').fetchone()[0] == 1


def test_persistent_source_failure_discovers_alternative_without_erasing_evidence(tmp_path):
    sources = [SOURCE, {**SOURCE, 'id': 'alternative', 'url': 'https://other.example.org/guide.xml'}]
    with seeded(tmp_path, sources) as conn:
        generation, ids, names = discovery.source_index(conn, NOW)
        assert len(discovery.candidates_for(channel(), ids, names)) == 2
        with conn:
            conn.execute("UPDATE source_health SET failures=3,state='failed' WHERE id='test'")
        following, ids, names = discovery.source_index(conn, NOW)
        assert following != generation
        proposals = discovery.candidates_for(channel(), ids, names)
        assert len(proposals) == 1 and proposals[0]['sourceId'] == 'alternative'
        assert conn.execute("SELECT count(*) FROM source_identities WHERE source_id='test'").fetchone()[0] == 1


def test_interrupted_batch_leases_expire_and_resume(tmp_path, monkeypatch):
    with seeded(tmp_path) as conn:
        discovery.sync_catalog(conn, {'version': 'a'}, [channel('a')], NOW)
        generation, ids, names = discovery.source_index(conn, NOW)
        original = discovery.candidates_for
        def interrupted(*args):
            raise KeyboardInterrupt()
        monkeypatch.setattr(discovery, 'candidates_for', interrupted)
        with pytest.raises(KeyboardInterrupt):
            discovery.process_batch(conn, generation, ids, names, NOW)
        monkeypatch.setattr(discovery, 'candidates_for', original)
        assert discovery.process_batch(conn, generation, ids, names, NOW + 119) == 0
        assert discovery.process_batch(conn, generation, ids, names, NOW + 120) == 1


def test_catalog_integrity_and_bounded_run_do_not_publish(tmp_path):
    with seeded(tmp_path):
        pass
    catalog(tmp_path, [channel(str(i)) for i in range(12)])
    times = iter([0, 1, 2, 30])
    first = discovery.run(tmp_path, NOW, clock=lambda: next(times))
    assert first['processedThisRun'] == 0 and first['states'] == {'pending': 12}
    assert first['identityReviewedEligibleChannels'] == 0 and first['sourceFirstMatchingEnabled'] is False
    assert first['publishedEpgVersion'] is None and first['verifiedCatalogMatches'] == 0
    assert discovery.run(tmp_path, NOW)['processedThisRun'] == 0
    assert discovery.run(tmp_path, NOW)['processedThisRun'] == 0
    manifest = json.loads((tmp_path / 'channel-catalog/manifest.json').read_text())
    (tmp_path / 'channel-catalog/snapshots' / (manifest['sha256'] + '.json.gz')).write_bytes(b'bad')
    with pytest.raises(epg.EpgError, match='checksum_mismatch'):
        discovery.load_catalog(tmp_path)


def test_china_hong_kong_taiwan_and_playable_priority():
    assert discovery.priority(channel()) < discovery.priority({**channel(), 'countryCode': 'US'})
    assert discovery.priority({**channel(), 'countryCode': 'HK'}) == discovery.priority(channel())
    assert discovery.priority(channel()) < discovery.priority({**channel(), 'routes': []})


def reviewed_rights(conn):
    import epg_store as store
    store.migrate(conn)
    store.approve_data_use(conn, SOURCE['id'], source_url=SOURCE['url'],
        evidence_url='https://fixture.example.org/data-permission', data_license='CC BY-SA 4.0',
        programme_data_permission=True, now=NOW,
        attribution={'sourceLabel': 'Synthetic fixture data',
            'attributionUrl': 'https://fixture.example.org/',
            'licenseUrl': 'https://creativecommons.org/licenses/by-sa/4.0/',
            'modificationNotice': 'Synthetic UTC normalization only.', 'shareAlikeRequired': True})


def test_licensed_mapped_identity_survives_programme_end_without_publishing_expired_data(tmp_path):
    import epg_store as store
    from epg_coverage import summarize
    with seeded(tmp_path) as conn:
        discovery.sync_catalog(conn, {'version': 'a'}, [channel()], NOW)
        reviewed_rights(conn)
        store.approve_mapping(conn, 'one', SOURCE['id'], 'CCTV5+', now=NOW, evidence={
            'evidenceUrl': 'https://fixture.example.org/exact-channel-version',
            'countryCode': 'CN', 'regionCode': None, 'sourceCountryCode': 'CN',
            'sourceRegionCode': None, 'sameChannelAndDelayVersion': True})
        store.ingest_batch(conn, SOURCE['id'], xml(), ['one'], fetched_at=NOW, now=NOW)
        assert summarize(conn, NOW)['currentAndFutureChannels'] == 1
        before, _, _ = discovery.source_index(conn, NOW)
        later = NOW + 2 * 3600 + 1
        after, ids, names = discovery.source_index(conn, later)
        assert after == before
        assert discovery.candidates_for(channel(), ids, names)[0]['programmeDataRightsVerified'] is True
        measured = summarize(conn, later)
        assert measured['verifiedMappings'] == 1
        assert measured['currentAndFutureChannels'] == 0
        assert measured['publishedCurrentAndFutureChannels'] == 0
        assert conn.execute('SELECT count(*) FROM epg_programmes').fetchone()[0] == 2
        with pytest.raises(epg.EpgError, match='no_publishable_current_future_data'):
            store.build_payload(conn, later)


def test_explicit_data_rights_change_review_metadata_never_channel_identity_or_mapping(tmp_path):
    with seeded(tmp_path) as conn:
        discovery.sync_catalog(conn, {'version': 'a'}, [channel()], NOW)
        before, ids, names = discovery.source_index(conn, NOW)
        discovery.process_batch(conn, before, ids, names, NOW)
        reviewed_rights(conn)
        after, ids, names = discovery.source_index(conn, NOW)
        assert after != before
        result = discovery.candidates_for(channel(), ids, names)[0]
        assert result['programmeDataRightsVerified'] is True
        assert result['dataRightsReview']['dataLicense'] == 'CC BY-SA 4.0'
        assert not result['contextVerified'] and not result['automaticallyApplied']
        assert result['confidence'] == 0.98
        assert discovery.process_batch(conn, after, ids, names, NOW + 1) == 1
        row = conn.execute('SELECT reason,candidates FROM discovery_jobs').fetchone()
        assert row['reason'] == 'identity_context_requires_review'
        assert json.loads(row['candidates'])[0]['programmeDataRightsVerified'] is True
        assert conn.execute('SELECT count(*) FROM mapping_review_audit').fetchone()[0] == 2
        assert conn.execute('SELECT count(*) FROM epg_mapping_approvals').fetchone()[0] == 0
        assert conn.execute('SELECT count(*) FROM epg_programmes').fetchone()[0] == 0


@pytest.mark.parametrize('damage', ['revoked', 'source-url', 'evidence-url', 'license',
    'missing-credit', 'corrupt-credit', 'missing-field', 'sharealike', 'private-credit-url'])
def test_invalid_or_revoked_data_rights_do_not_mark_candidate_permitted(tmp_path, damage):
    with seeded(tmp_path) as conn:
        reviewed_rights(conn)
        approved, _, _ = discovery.source_index(conn, NOW)
        with conn:
            if damage == 'revoked':
                conn.execute('UPDATE epg_data_grants SET revoked=1')
            elif damage == 'source-url':
                conn.execute("UPDATE epg_data_grants SET source_url='https://other.example.org/guide.xml'")
            elif damage == 'evidence-url':
                conn.execute("UPDATE epg_data_grants SET evidence_url='https://localhost/permission'")
            elif damage == 'license':
                conn.execute("UPDATE epg_data_grants SET data_license=''")
            elif damage == 'missing-credit':
                conn.execute('DELETE FROM epg_data_attributions')
            elif damage == 'corrupt-credit':
                conn.execute("UPDATE epg_data_attributions SET metadata='broken-json'")
            else:
                credit = json.loads(conn.execute('SELECT metadata FROM epg_data_attributions').fetchone()[0])
                if damage == 'missing-field':
                    del credit['modificationNotice']
                elif damage == 'sharealike':
                    credit['shareAlikeRequired'] = False
                else:
                    credit['attributionUrl'] = 'https://localhost/'
                conn.execute('UPDATE epg_data_attributions SET metadata=?', (json.dumps(credit),))
        after, ids, names = discovery.source_index(conn, NOW)
        assert after != approved
        result = discovery.candidates_for(channel(), ids, names)[0]
        assert result['programmeDataRightsVerified'] is False
        assert result['dataRightsReview'] is None
        assert not result['contextVerified'] and not result['automaticallyApplied']


def test_data_rights_probe_is_readonly_and_registry_license_text_alone_is_insufficient(tmp_path):
    import epg_store as store
    with seeded(tmp_path) as conn:
        before = conn.total_changes
        assert store.reviewed_data_use(conn, SOURCE['id']) is None
        assert conn.total_changes == before
        assert not conn.execute("SELECT 1 FROM sqlite_master WHERE name='epg_data_grants'").fetchone()
        reviewed_rights(conn)
        before = conn.total_changes
        assert store.reviewed_data_use(conn, SOURCE['id']) is not None
        assert conn.total_changes == before and not conn.in_transaction
