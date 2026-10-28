"""Explicit structured IDs can propose review; they never authorize a feed."""
import json
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_discovery as discovery
import epg_ingest as epg
import epg_store as store

NOW = 1792175000
SOURCE = 'fixture-de-licensed'


def setup(conn, licensed=True, country='DE', source_name='RTL', format='tvmaze-json'):
    discovery.migrate(conn)
    store.migrate(conn)
    config = {'url': 'https://api.tvmaze.com/schedule', 'format': format,
        'countryCode': country, 'refreshSeconds': 3600}
    conn.execute('INSERT INTO source_health(id,url,configuration,state,last_success) VALUES(?,?,?,?,?)',
        (SOURCE, config['url'], json.dumps(config), 'healthy', NOW))
    conn.execute('INSERT INTO source_identities VALUES(?,?,?,?,?,?,?,?,?)',
        (SOURCE, 'tvmaze-network-164', json.dumps([source_name]), NOW, NOW, 'a'*64,
         'synthetic_fixture', NOW-60, NOW+3600))
    context = {'countryCode': country, 'originalNetworkId': 164,
        'sourceTimezone': 'Europe/Busingen', 'contextVerifiedForCatalog': False}
    conn.execute('INSERT INTO source_identity_context VALUES(?,?,?,?)',
        (SOURCE, 'tvmaze-network-164', json.dumps(context), NOW))
    conn.commit()
    if licensed:
        store.approve_data_use(conn, SOURCE, source_url=config['url'],
            evidence_url='https://www.tvmaze.com/api', data_license='CC BY-SA 4.0',
            programme_data_permission=True, now=NOW,
            attribution={'sourceLabel': 'TVmaze', 'attributionUrl': 'https://www.tvmaze.com/',
                'licenseUrl': 'https://creativecommons.org/licenses/by-sa/4.0/',
                'modificationNotice': 'Synthetic regression fixture only.', 'shareAlikeRequired': True})


def channel(epg_id='RTL.de@SD', country='DE', name='RTL (Germany)'):
    return {'id': 'fixture-rtl', 'name': name, 'epgId': epg_id,
        'countryCode': country, 'regionCode': None, 'routes': []}


def test_licensed_explicit_country_identifier_enters_review_without_approval(tmp_path):
    with epg.database(tmp_path) as conn:
        setup(conn)
        target = channel()
        discovery.sync_catalog(conn, {'version': 'fixture-one'}, [target], NOW)
        generation, ids, names = discovery.source_index(conn, NOW)
        result = discovery.candidates_for(target, ids, names)
        assert len(result) == 1
        assert result[0]['identityEvidence'] == 'structured_country_identifier_requires_feed_review'
        assert result[0]['confidence'] == 0.45
        assert result[0]['structuredIdentifierEvidence']['retainedVariant'] == 'SD'
        assert result[0]['structuredIdentifierEvidence']['feedVariantVerified'] is False
        assert result[0]['contextVerified'] is False and result[0]['automaticallyApplied'] is False
        assert discovery.process_batch(conn, generation, ids, names, NOW) == 1
        assert conn.execute('SELECT state FROM discovery_jobs').fetchone()[0] == 'review'
        assert discovery.process_batch(conn, generation, ids, names, NOW) == 0
        assert conn.execute('SELECT count(*) FROM mapping_review_audit').fetchone()[0] == 1
        with pytest.raises(epg.EpgError, match='identity_context_unverified'):
            store.approve_mapping(conn, target['id'], SOURCE, 'tvmaze-network-164',
                evidence={'evidenceUrl': 'https://www.tvmaze.com/api', 'countryCode': 'DE',
                    'sourceCountryCode': 'DE', 'regionCode': None, 'sourceRegionCode': None,
                    'sameChannelAndDelayVersion': False}, now=NOW)
        for table in ('epg_mapping_approvals', 'epg_programmes', 'epg_source_payloads', 'epg_publication_audit'):
            assert conn.execute('SELECT count(*) FROM '+table).fetchone()[0] == 0


def test_full_name_and_broadcaster_route_do_not_approve_missing_catalog_country(tmp_path):
    """Unknown catalogue geography remains a review even after a source recovers."""
    with epg.database(tmp_path) as conn:
        setup(conn, licensed=False, country='NO', source_name='Frikanalen', format='xmltv')
        conn.execute('DELETE FROM source_identity_context WHERE source_id=?', (SOURCE,))
        conn.commit()
        target = channel(epg_id='Frikanalen.no', country=None, name='Frikanalen')
        target['routes'] = [{'url': 'https://frikanalen.no/stream/index.m3u8'}]
        discovery.sync_catalog(conn, {'version': 'fixture-missing-country'}, [target], NOW)
        generation, ids, names = discovery.source_index(conn, NOW)
        proposals = discovery.candidates_for(target, ids, names)
        assert len(proposals) == 1
        assert proposals[0]['identityEvidence'] == 'exact_full_name_only'
        assert proposals[0]['confidence'] == 0.55
        assert proposals[0]['countryCode'] is None
        assert proposals[0]['sourceIdentityContext'] == {}
        assert proposals[0]['contextVerified'] is False
        assert proposals[0]['programmeDataRightsVerified'] is False
        assert proposals[0]['automaticallyApplied'] is False
        assert discovery.process_batch(conn, generation, ids, names, NOW) == 1
        assert conn.execute('SELECT state FROM discovery_jobs').fetchone()[0] == 'review'
        assert discovery.process_batch(conn, generation, ids, names, NOW) == 0
        assert conn.execute('SELECT count(*) FROM mapping_review_audit').fetchone()[0] == 1
        with pytest.raises(epg.EpgError, match='catalog_context_mismatch'):
            store.approve_mapping(conn, target['id'], SOURCE, 'tvmaze-network-164',
                evidence={'evidenceUrl': 'https://frikanalen.no/', 'countryCode': 'NO',
                    'sourceCountryCode': 'NO', 'regionCode': None, 'sourceRegionCode': None,
                    'sameChannelAndDelayVersion': True}, now=NOW)
        for table in ('epg_data_grants', 'epg_mapping_approvals', 'epg_programmes',
                      'epg_source_payloads', 'epg_publication_audit'):
            assert conn.execute('SELECT count(*) FROM '+table).fetchone()[0] == 0


@pytest.mark.parametrize('epg_id,country', [
    ('RTL.at@SD', 'DE'), ('RTL.de@SD', 'AT'), ('RTL.de@+1', 'DE'),
    ('RTL.de@Plus1', 'DE'), ('RTL.de@timeshift', 'DE'),
    ('RTL.de@delayWest', 'DE'), ('RTL.de/SD', 'DE'), ('RTLNews.de', 'DE'),
    ('RTL.de@SD extra', 'DE'),
])
def test_country_delayed_and_nonexact_identifiers_do_not_propose_original_feed(tmp_path, epg_id, country):
    with epg.database(tmp_path) as conn:
        setup(conn)
        _, ids, names = discovery.source_index(conn, NOW)
        assert discovery.candidates_for(channel(epg_id, country), ids, names) == []


@pytest.mark.parametrize('licensed,format,source_name', [
    (False, 'tvmaze-json', 'RTL'), (True, 'xmltv', 'RTL'),
    (True, 'tvmaze-json', 'RTL+'), (True, 'tvmaze-json', 'RTL News'),
])
def test_structured_review_requires_current_grant_supported_provider_and_whole_name(tmp_path, licensed, format, source_name):
    with epg.database(tmp_path) as conn:
        setup(conn, licensed=licensed, format=format, source_name=source_name)
        _, ids, names = discovery.source_index(conn, NOW)
        assert discovery.candidates_for(channel(), ids, names) == []


@pytest.mark.parametrize('name,epg_id', [('NBC WGBA-TV', 'NBC.us@WGBATV'), ('ABC WMAR-TV', 'ABC.us@WMARTV')])
def test_us_affiliates_remain_unmatched_by_structured_network_identifier(tmp_path, name, epg_id):
    with epg.database(tmp_path) as conn:
        setup(conn, country='US', source_name=epg_id.split('.')[0])
        _, ids, names = discovery.source_index(conn, NOW)
        assert discovery.candidates_for(channel(epg_id, 'US', name), ids, names) == []


def test_uk_country_identifier_keeps_regional_variant_unverified(tmp_path):
    with epg.database(tmp_path) as conn:
        setup(conn, country='GB', source_name='BBC One')
        _, ids, names = discovery.source_index(conn, NOW)
        result = discovery.candidates_for(channel('BBCOne.uk@London', 'GB', 'BBC One (London)'), ids, names)
        assert len(result) == 1
        assert result[0]['structuredIdentifierEvidence']['countryCode'] == 'GB'
        assert result[0]['structuredIdentifierEvidence']['retainedVariant'] == 'London'
        assert result[0]['contextVerified'] is False
