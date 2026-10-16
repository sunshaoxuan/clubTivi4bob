"""Regression cases from public metadata triage, never production approvals."""
import json
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_discovery as discovery
import epg_ingest as epg
import epg_store as store

NOW = 1792163100
SOURCE_ID = 'fixture-licensed-network'
API = 'https://api.tvmaze.com/schedule'
CASES = [
    ('NBC WGBA-TV', 'NBC.us@WGBATV', 1, 'NBC'),
    ('ABC WMAR-TV', 'ABC.us@WMARTV', 3, 'ABC'),
    ('ABC WWAY', 'ABC.us@WWAY', 3, 'ABC'),
    ('ABC KOAT-TV', 'ABC.us@KOATTV', 3, 'ABC'),
    ('NBC WGAL', 'NBC.us@WGAL', 1, 'NBC'),
]


@pytest.mark.parametrize('name,epg_id,network_id,network_name', CASES)
def test_licensed_network_facts_never_implicitly_approve_local_affiliate(tmp_path, name, epg_id, network_id, network_name):
    conn = epg.database(tmp_path)
    try:
        discovery.migrate(conn)
        store.migrate(conn)
        config = {'url': API, 'format': 'tvmaze-json', 'countryCode': 'US',
            'calendarTimezone': 'America/New_York', 'refreshSeconds': 3600}
        original_id = 'tvmaze-network-' + str(network_id)
        context = {'countryCode': 'US', 'originalNetworkId': network_id,
            'sourceTimezone': 'America/New_York', 'contextVerifiedForCatalog': False}
        conn.execute('''INSERT INTO source_health(id,url,configuration,state,last_success)
            VALUES(?,?,?,?,?)''', (SOURCE_ID, API, json.dumps(config), 'healthy', NOW))
        conn.execute('INSERT INTO source_identities VALUES(?,?,?,?,?,?,?,?,?)',
            (SOURCE_ID, original_id, json.dumps([network_name]), NOW, NOW,
             'a' * 64, 'synthetic_test_fixture', NOW - 60, NOW + 3600))
        conn.execute('INSERT INTO source_identity_context VALUES(?,?,?,?)',
            (SOURCE_ID, original_id, json.dumps(context), NOW))
        conn.commit()
        store.approve_data_use(conn, SOURCE_ID, source_url=API,
            evidence_url='https://www.tvmaze.com/api', data_license='CC BY-SA 4.0',
            programme_data_permission=True, now=NOW,
            attribution={'sourceLabel': 'TVmaze', 'attributionUrl': 'https://www.tvmaze.com/',
                'licenseUrl': 'https://creativecommons.org/licenses/by-sa/4.0/',
                'modificationNotice': 'Synthetic fixture only; not production programme data.',
                'shareAlikeRequired': True})
        channel = {'id': 'fixture-local-station', 'name': name, 'epgId': epg_id,
            'countryCode': 'US', 'regionCode': None, 'routes': []}
        discovery.sync_catalog(conn, {'version': 'fixture-one'}, [channel], NOW)
        generation, ids, names = discovery.source_index(conn, NOW)
        assert store.reviewed_data_use(conn, SOURCE_ID)
        assert discovery.candidates_for(channel, ids, names) == []
        assert discovery.process_batch(conn, generation, ids, names, NOW) == 1
        first = conn.execute('SELECT * FROM mapping_review_audit').fetchone()
        job = conn.execute('SELECT * FROM discovery_jobs').fetchone()
        assert job['state'] == 'unmatched' and job['reason'] == 'no_strict_candidate'
        assert json.loads(job['payload'])['epgId'] == epg_id

        # Even a lossy display-name collision cannot turn permission into exact
        # affiliate, timezone-edition or delay-version evidence.
        generic = {**channel, 'name': network_name}
        discovery.sync_catalog(conn, {'version': 'fixture-two'}, [generic], NOW + 1)
        assert discovery.process_batch(conn, generation, ids, names, NOW + 1) == 1
        job = conn.execute('SELECT * FROM discovery_jobs').fetchone()
        assert job['state'] == 'review'
        proposals = json.loads(job['candidates'])
        assert len(proposals) == 1 and proposals[0]['programmeDataRightsVerified'] is True
        assert proposals[0]['contextVerified'] is False and proposals[0]['automaticallyApplied'] is False
        assert json.loads(job['payload'])['epgId'] == epg_id
        with pytest.raises(epg.EpgError, match='identity_context_unverified'):
            store.approve_mapping(conn, channel['id'], SOURCE_ID, original_id,
                evidence={'evidenceUrl': 'https://www.tvmaze.com/api', 'countryCode': 'US',
                    'regionCode': None, 'sourceCountryCode': 'US', 'sourceRegionCode': None,
                    'sameChannelAndDelayVersion': False}, now=NOW + 1)
        assert tuple(conn.execute('SELECT * FROM mapping_review_audit WHERE id=?', (first['id'],)).fetchone()) == tuple(first)
        assert conn.execute('SELECT count(*) FROM mapping_review_audit').fetchone()[0] == 2
        for table in ('epg_mapping_approvals', 'epg_programmes', 'epg_source_payloads', 'epg_publication_audit'):
            assert conn.execute('SELECT count(*) FROM ' + table).fetchone()[0] == 0
    finally:
        conn.close()
