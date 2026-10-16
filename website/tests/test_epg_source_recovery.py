import json
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_discovery as discovery
import epg_ingest as ingest
import epg_source_discovery as provider
import epg_source_recovery as recovery
import epg_store as store

NOW = 1792156800
CN = {**provider.source_for('HK'), 'id': 'tvmaze-cn-diagnostic-v1',
    'countryCode': 'CN', 'calendarTimezone': 'Asia/Shanghai'}
XML = [{'id': identity, 'url': url, 'refreshSeconds': 21600,
    'publicationAllowed': False, 'dataLicense': {'status': 'unverified'}}
    for identity, (url, country) in recovery.XML_SCOPES.items() if country == 'CN']
CHANNELS = [{'id': 'catalog-cn', 'countryCode': 'CN'}]


@pytest.fixture
def conn(tmp_path):
    connection = ingest.database(tmp_path)
    discovery.migrate(connection)
    store.migrate(connection)
    yield connection
    connection.close()


def seed(conn, source, *, state='healthy', failures=0, end=NOW + 3600,
         success=NOW - 60, error=None):
    quality = {'acceptedProgrammes': 2, 'currentAndFutureChannels': 1,
        'coverageEndUtc': end} if success is not None else None
    conn.execute('''INSERT INTO source_health(id,url,configuration,state,failures,
      last_success,last_failure,next_retry,last_error,content_sha256,last_good_quality)
      VALUES(?,?,?,?,?,?,?,?,?,?,?)''', (source['id'], source['url'], json.dumps(source, sort_keys=True),
        state, failures, success, NOW - 30 if failures else None, NOW + 3600, error,
        'a' * 64, json.dumps(quality)))
    if success is not None:
        conn.execute('INSERT INTO source_identities VALUES(?,?,?,?,?,?,?,?,?)',
            (source['id'], 'fixture-network', '["Fixture"]', success, success, 'a' * 64,
             'test_fixture', NOW - 300, end))
    conn.commit()


def fail(conn, source=CN, failures=3):
    seed(conn, source, state='failed', failures=failures, success=None, error='network_failure')


def run(conn, sources=None, channels=CHANNELS, now=NOW, limit=5):
    return recovery.run(conn, sources or [CN] + XML, channels, now, limit)


def jobs(conn):
    return [dict(row) for row in conn.execute('SELECT * FROM epg_source_recovery_jobs ORDER BY source_id')]


def test_single_temporary_failure_does_not_become_permanent_failure(conn):
    fail(conn, failures=1)
    assert run(conn)['checkedSources'] == 0
    assert jobs(conn) == []


def test_sustained_failure_finds_cached_cross_provider_candidates_without_approval_or_fetch(conn):
    fail(conn)
    for source in XML:
        seed(conn, source)
    before = [tuple(row) for row in conn.execute('SELECT * FROM source_health ORDER BY id')]
    result = run(conn)
    assert result['checkedSources'] == 1 and result['newNetworkRequests'] == 0
    assert result['jobStates'] == {'candidates_require_review': 1}
    row = jobs(conn)[0]
    evidence = json.loads(row['evidence'])
    assert row['reason'] == 'sustained_fetch_failure'
    assert len(evidence['alternatives']) == 2
    assert all(not item['programmeDataRightsVerified'] and not item['exactCatalogIdentityVerified']
        and not item['automaticallyApplied'] for item in evidence['alternatives'])
    assert [tuple(row) for row in conn.execute('SELECT * FROM source_health ORDER BY id')] == before
    for table in ('epg_data_grants', 'epg_data_attributions', 'epg_mapping_approvals',
                  'epg_programmes', 'epg_source_payloads', 'source_replacements', 'epg_publication_audit'):
        assert conn.execute('SELECT count(*) FROM ' + table).fetchone()[0] == 0


def test_idle_and_unchanged_reviews_are_idempotent_and_keep_backoff(conn):
    fail(conn)
    seed(conn, XML[0])
    run(conn)
    assert run(conn, now=NOW + 1)['checkedSources'] == 0
    assert run(conn, now=NOW + 301)['checkedSources'] == 1
    assert conn.execute('SELECT count(*) FROM epg_source_recovery_audit').fetchone()[0] == 1
    assert conn.execute('SELECT next_retry FROM source_health WHERE id=?', (CN['id'],)).fetchone()[0] == NOW + 3600


def test_expired_last_good_data_triggers_review_and_expired_alternative_is_rejected(conn):
    seed(conn, CN, failures=1, state='failed', end=NOW - 1, error='network_failure')
    seed(conn, XML[0], end=NOW)
    assert run(conn)['jobStates'] == {'needs_alternative_provider': 2}
    row = next(row for row in jobs(conn) if row['source_id'] == CN['id'])
    assert row['reason'] == 'last_good_coverage_expired'
    assert json.loads(row['evidence'])['alternatives'] == []
    assert conn.execute('SELECT count(*) FROM source_identities').fetchone()[0] == 2


def test_recovery_is_audited_without_deleting_prior_job_or_history(conn):
    fail(conn)
    run(conn)
    conn.execute('UPDATE source_health SET state=?,failures=0,last_error=NULL,last_success=?,last_good_quality=? WHERE id=?',
        ('healthy', NOW + 300, json.dumps({'coverageEndUtc': NOW + 7200}), CN['id']))
    conn.commit()
    assert run(conn, now=NOW + 301)['jobStates'] == {}
    assert jobs(conn)[0]['state'] == 'recovered' and jobs(conn)[0]['active'] == 0
    assert conn.execute('SELECT count(*) FROM epg_source_recovery_audit').fetchone()[0] == 2


def test_three_partial_probes_trigger_rediscovery_but_one_partial_does_not(conn):
    seed(conn, CN, state='partial')
    for index in range(3):
        conn.execute('INSERT INTO probe_audit(source_id,checked_at,state) VALUES(?,?,?)', (CN['id'], NOW - index, 'partial'))
        conn.commit()
        result = run(conn, now=NOW + index)
        assert result['checkedSources'] == int(index == 2)
    assert jobs(conn)[0]['reason'] == 'sustained_partial_coverage'


def test_unknown_scope_changed_url_and_same_provider_are_not_alternatives(conn):
    fail(conn)
    changed = {**XML[0], 'url': 'https://unreviewed.example/guide.xml'}
    same_provider = {**CN, 'id': 'same-provider'}
    seed(conn, changed)
    seed(conn, same_provider)
    result = run(conn, [CN, changed, same_provider], channels=CHANNELS + [{'id': 'unknown', 'countryCode': None}])
    assert result['jobStates'] == {'needs_alternative_provider': 1}
    assert json.loads(jobs(conn)[0]['evidence'])['alternatives'] == []


@pytest.mark.parametrize('error', ['http_401', 'http_403'])
def test_access_denied_requires_manual_review_without_alternative_activation(conn, error):
    seed(conn, CN, state='failed', failures=1, success=None, error=error)
    seed(conn, XML[0])
    assert run(conn)['jobStates'] == {'manual_review': 1}
    assert json.loads(jobs(conn)[0]['evidence'])['alternatives'] == []


def test_configuration_drift_fails_closed_and_catalog_country_removal_keeps_history(conn):
    fail(conn)
    conn.execute('UPDATE source_health SET configuration=? WHERE id=?', ('{}', CN['id']))
    conn.commit()
    assert run(conn)['jobStates'] == {'manual_review': 1}
    assert run(conn, channels=[])['jobStates'] == {}
    assert jobs(conn)[0]['state'] == 'inactive_source'
    assert conn.execute('SELECT count(*) FROM epg_source_recovery_audit').fetchone()[0] == 1


def test_max_five_per_batch_and_due_queue_does_not_starve_later_sources(conn):
    sources = [provider.source_for(country) for country in ('HK', 'TW', 'FR', 'CA', 'JP', 'DE')]
    channels = [{'id': source['id'], 'countryCode': source['countryCode']} for source in sources]
    for source in sources:
        fail(conn, source)
    assert run(conn, sources, channels)['checkedSources'] == 5
    assert run(conn, sources, channels, NOW + 1)['checkedSources'] == 1
    assert len(jobs(conn)) == 6


@pytest.mark.parametrize('limit', [0, 6, True])
def test_invalid_batch_size_rejected(conn, limit):
    with pytest.raises(ingest.EpgError, match='recovery_batch_size_limit'):
        run(conn, limit=limit)
