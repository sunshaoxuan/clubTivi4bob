from datetime import datetime
import json
from pathlib import Path
import sys
from zoneinfo import ZoneInfo

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_ingest as epg
import epg_source_discovery as worker

NOW = epg.timestamp('20261016150000 +0000')
MANIFEST = {'version': 'fixture-v1'}


def channel(country, suffix='1', playable=False):
    return {'id': str(country) + suffix, 'countryCode': country,
        'routes': [{'lastPlayableAt': '2026-10-16T14:00:00Z'}] if playable else []}


def payload(country, start=NOW + 600):
    local = datetime.fromtimestamp(start, ZoneInfo(worker.CALENDARS[country]))
    return json.dumps([{'id': 1, 'airstamp': datetime.fromtimestamp(start, ZoneInfo('UTC')).isoformat(),
        'airdate': local.date().isoformat(), 'airtime': local.strftime('%H:%M'), 'runtime': 10,
        'show': {'name': 'Fixture', 'network': {'id': 5, 'name': 'Fixture network',
            'country': {'code': country, 'timezone': worker.CALENDARS[country]}}}}]).encode()


def run(directory, channels, now=NOW, fetcher=None, configured=()):
    return worker.run(directory, MANIFEST, channels, configured, now,
        fetcher=fetcher or (lambda source: (payload(source['countryCode'], now + 600), {})))


def rows(directory, table):
    with epg.database(directory) as conn:
        return [dict(row) for row in conn.execute('SELECT * FROM ' + table)]


def test_one_serial_request_prioritizes_catalogue_hk_and_playable_public_routes(tmp_path):
    calls = []
    result = run(tmp_path, [channel('FR', playable=True), channel('TW'), channel('HK', playable=True)],
        fetcher=lambda source: (calls.append(source['countryCode']) or payload(source['countryCode']), {}))
    assert calls == ['HK'] and result['attemptedSources'] == 1
    assert result['activeJobs'] == 3 and result['published'] is False
    assert result['automaticMappingApproval'] is False and result['supportedProviderCount'] == 1
    assert len(rows(tmp_path, 'probe_audit')) == 2


def test_catalogue_sync_idempotent_new_country_added_removed_country_inactive(tmp_path):
    run(tmp_path, [channel('FR')])
    before = rows(tmp_path, 'epg_source_discovery_audit')
    result = run(tmp_path, [channel('FR')], NOW + 10, lambda _: pytest.fail('cache must be respected'))
    assert result['attemptedSources'] == 0
    assert rows(tmp_path, 'epg_source_discovery_audit') == before
    run(tmp_path, [channel('CA')], NOW + 20)
    jobs = {r['country']: r for r in rows(tmp_path, 'epg_source_discovery_jobs')}
    assert jobs['FR']['active'] == 0 and jobs['CA']['active'] == 1
    assert jobs['FR']['last_attempt'] == NOW


def test_expanded_country_queue_keeps_one_fetch_and_existing_cooldowns_audits(tmp_path):
    original = [channel('HK'), channel('TW'), channel('FR')]
    run(tmp_path, original, fetcher=lambda _: (b'[]', {}))
    run(tmp_path, original, NOW + 1, fetcher=lambda _: (b'[]', {}))
    run(tmp_path, original, NOW + 2)
    previous_jobs = {r['country']: r for r in rows(tmp_path, 'epg_source_discovery_jobs')}
    previous_health = rows(tmp_path, 'source_health')
    previous_audits = rows(tmp_path, 'epg_source_discovery_audit')
    expanded = original + [channel(c, playable=True) for c in ('KR', 'AU', 'NZ', 'ES', 'NL')]
    calls = []
    result = run(tmp_path, expanded, NOW + 60,
        fetcher=lambda source: (calls.append(source['countryCode']) or payload(source['countryCode']), {}))
    assert calls == ['AU'] and result['attemptedSources'] == 1 and result['activeJobs'] == 8
    jobs = {r['country']: r for r in rows(tmp_path, 'epg_source_discovery_jobs')}
    for country in ('HK', 'TW', 'FR'):
        for field in ('first_seen', 'last_attempt', 'next_retry', 'failures', 'state', 'last_error'):
            assert jobs[country][field] == previous_jobs[country][field]
    assert [r for r in rows(tmp_path, 'source_health') if r['id'] != worker.source_for('AU')['id']] == previous_health
    assert rows(tmp_path, 'epg_source_discovery_audit')[:len(previous_audits)] == previous_audits
    assert all(jobs[c]['state'] == 'pending' for c in ('KR', 'NZ', 'ES', 'NL'))
    assert result['automaticMappingApproval'] is False and result['published'] is False


@pytest.mark.parametrize('country,day', [
    ('KR', '2026-10-16'), ('AU', '2026-10-17'), ('NZ', '2026-10-17'),
    ('ES', '2026-10-16'), ('NL', '2026-10-16'),
])
def test_expanded_calendar_day_boundary_keeps_explicit_source_timezone(tmp_path, country, day):
    now = epg.timestamp('20261016143000 +0000')
    source = worker.source_for(country)
    assert epg.source_day(source, now) == day
    result = run(tmp_path, [channel(country)], now)
    assert result['attemptedSources'] == 1 and result['safeError'] is None
    assert result['published'] is False
    health = rows(tmp_path, 'source_health')[0]
    assert health['last_success'] == now and health['next_retry'] >= now + 3600
    identity = rows(tmp_path, 'source_identity_context')[0]
    context = json.loads(identity['context_json'])
    assert context['sourceTimezone'] == worker.CALENDARS[country]
    assert context['contextVerifiedForCatalog'] is False


@pytest.mark.parametrize('country,network_timezone', [
    ('AU', 'Australia/Perth'), ('NZ', 'Pacific/Chatham'),
])
def test_expanded_country_calendar_never_overrides_explicit_network_timezone(country, network_timezone):
    now = epg.timestamp('20261016143000 +0000')
    start = epg.timestamp('20261016181000 +0000')
    source = worker.source_for(country)
    row = json.loads(payload(country, start))[0]
    local = datetime.fromtimestamp(start, ZoneInfo(network_timezone))
    row['airdate'], row['airtime'] = local.date().isoformat(), local.strftime('%H:%M')
    row['show']['network']['country']['timezone'] = network_timezone
    parsed = epg.parse_source(source, json.dumps([row]).encode(), now)
    assert parsed['quality']['acceptedProgrammes'] == 1
    assert parsed['programmes'][0]['startUtc'] == start
    assert parsed['programmes'][0]['sourceTimezone'] == network_timezone
    assert parsed['programmes'][0]['endBasis'] == 'start_plus_explicit_episode_runtime'
    assert parsed['identityContexts']['tvmaze-network-5']['contextVerifiedForCatalog'] is False
    row['airtime'] = datetime.fromtimestamp(start, ZoneInfo(worker.CALENDARS[country])).strftime('%H:%M')
    parsed = epg.parse_source(source, json.dumps([row]).encode(), now)
    assert parsed['quality']['acceptedProgrammes'] == 0
    assert parsed['quality']['rejected'] == {'source_local_time_mismatch': 1}


def test_existing_provider_country_not_duplicated_and_unknown_countries_ignored(tmp_path):
    existing = worker.source_for('FR')
    result = run(tmp_path, [channel('FR'), channel('ZZ'), channel('GB'), channel(None)], configured=[existing])
    assert result['activeJobs'] == result['attemptedSources'] == 0
    assert rows(tmp_path, 'source_health') == []


def test_bootstrap_manual_probe_cooldown_not_relabelled_as_success(tmp_path):
    now = worker.BOOTSTRAP_NOT_BEFORE['IT'] - 1
    result = run(tmp_path, [channel('IT')], now, lambda _: pytest.fail('manual cache window'))
    assert result['attemptedSources'] == 0
    job = rows(tmp_path, 'epg_source_discovery_jobs')[0]
    assert job['last_attempt'] is None and job['state'] == 'pending'
    assert rows(tmp_path, 'source_health') == []


def test_sparse_future_keeps_metadata_without_grants_mappings_or_programme_rows(tmp_path):
    result = run(tmp_path, [channel('FR')])
    assert result['jobStates'] == {'partial': 1}
    assert rows(tmp_path, 'source_identities')[0]['source_id'] == 'tvmaze-discovery-fr-v1'
    assert json.loads(rows(tmp_path, 'source_identity_context')[0]['context_json'])['contextVerifiedForCatalog'] is False
    with epg.database(tmp_path) as conn:
        for table in ('epg_programmes', 'epg_source_payloads', 'epg_data_grants', 'epg_mapping_approvals'):
            if conn.execute('SELECT 1 FROM sqlite_master WHERE name=?', (table,)).fetchone():
                assert conn.execute('SELECT count(*) FROM ' + table).fetchone()[0] == 0
    assert result['published'] is False


def test_empty_and_stale_only_are_failures_with_exponential_backoff(tmp_path):
    first = run(tmp_path, [channel('FR')], fetcher=lambda _: (b'[]', {}))
    assert first['safeError'] == 'empty_or_expired_data'
    job = rows(tmp_path, 'epg_source_discovery_jobs')[0]
    assert job['failures'] == 1 and job['next_retry'] >= NOW + 3600
    run(tmp_path, [channel('FR')], NOW + 3599, lambda _: pytest.fail('too soon'))
    second = run(tmp_path, [channel('FR')], NOW + 3600,
        lambda _: (payload('FR', NOW - 3600), {}))
    assert second['safeError'] == 'insufficient_current_future_coverage'
    job = rows(tmp_path, 'epg_source_discovery_jobs')[0]
    assert job['failures'] == 2 and job['next_retry'] >= NOW + 3 * 3600
    assert rows(tmp_path, 'source_health')[0]['next_retry'] == job['next_retry']


def test_existing_longer_queue_backoff_is_retained_in_health_and_recovery_without_fetch(tmp_path):
    run(tmp_path, [channel('FR')], fetcher=lambda _: (b'[]', {}))
    with epg.database(tmp_path) as conn:
        conn.execute('UPDATE epg_source_discovery_jobs SET failures=3,next_retry=?', (NOW + 7200,))
        conn.execute('UPDATE source_health SET failures=3,next_retry=?', (NOW + 3600,))
        conn.commit()
    result = run(tmp_path, [channel('FR')], NOW + 60, lambda _: pytest.fail('queue backoff'))
    assert result['attemptedSources'] == 0
    assert rows(tmp_path, 'source_health')[0]['next_retry'] == NOW + 7200
    evidence = json.loads(rows(tmp_path, 'epg_source_recovery_jobs')[0]['evidence'])
    assert evidence['nextSourceRetry'] == NOW + 7200
    assert evidence['newNetworkRequests'] == 0
    before = rows(tmp_path, 'probe_audit')
    run(tmp_path, [channel('FR')], NOW + 120, lambda _: pytest.fail('still cooling down'))
    result = run(tmp_path, [channel('FR')], NOW + 3601, lambda _: pytest.fail('older health deadline passed'))
    assert result['attemptedSources'] == 0
    validator = epg.probe_batch(tmp_path, [worker.source_for('FR')], NOW + 3601,
        lambda _: pytest.fail('independent consumer must retain longer queue backoff'))
    assert validator['attemptedSources'] == 0
    assert rows(tmp_path, 'probe_audit') == before


def test_longer_health_retry_is_not_shortened_or_applied_to_configuration_drift(tmp_path):
    run(tmp_path, [channel('FR')])
    with epg.database(tmp_path) as conn:
        conn.execute('UPDATE source_health SET next_retry=?', (NOW + 10800,))
        conn.commit()
    run(tmp_path, [channel('FR')], NOW + 60, lambda _: pytest.fail('health backoff'))
    assert rows(tmp_path, 'epg_source_discovery_jobs')[0]['next_retry'] == NOW + 10800
    with epg.database(tmp_path) as conn:
        conn.execute('UPDATE source_health SET configuration=?,next_retry=?', ('{}', NOW + 1800))
        conn.commit()
    run(tmp_path, [channel('FR')], NOW + 120, lambda _: pytest.fail('configuration drift'))
    assert rows(tmp_path, 'source_health')[0]['next_retry'] == NOW + 1800
    assert rows(tmp_path, 'epg_source_discovery_jobs')[0]['next_retry'] == NOW + 10800


def test_timeout_preserves_last_good_then_recovers_without_duplicate_job(tmp_path):
    run(tmp_path, [channel('FR')])
    previous = rows(tmp_path, 'source_identities')
    def timeout(_):
        raise TimeoutError()
    result = run(tmp_path, [channel('FR')], NOW + 3600, timeout)
    assert result['safeError'] == 'network_failure'
    assert rows(tmp_path, 'source_identities') == previous
    result = run(tmp_path, [channel('FR')], NOW + 7200)
    assert result['safeError'] is None and result['jobStates'] == {'partial': 1}
    assert len(rows(tmp_path, 'epg_source_discovery_jobs')) == 1
    assert rows(tmp_path, 'epg_source_discovery_jobs')[0]['failures'] == 0


def test_provider_429_shared_across_discovery_countries_and_existing_validator(tmp_path):
    def limited(_):
        raise epg.EpgError('http_429', 7200)
    result = run(tmp_path, [channel('FR'), channel('CA')], fetcher=limited)
    assert result['providerRetryAtUtc'] >= NOW + 7200
    run(tmp_path, [channel('FR'), channel('CA')], NOW + 60, lambda _: pytest.fail('provider limited'))
    other = epg.probe_batch(tmp_path, [worker.source_for('JP')], NOW + 60,
        lambda _: pytest.fail('shared upstream rate limit'))
    assert other['attemptedSources'] == 0


@pytest.mark.parametrize('code', ['http_401', 'http_403'])
def test_auth_or_access_denied_needs_manual_review_without_automatic_retry(tmp_path, code):
    def denied(_):
        raise epg.EpgError(code)
    result = run(tmp_path, [channel('FR')], fetcher=denied)
    assert result['jobStates'] == {'manual_review': 1}
    run(tmp_path, [channel('FR')], NOW + 86400, lambda _: pytest.fail('manual intervention required'))


def test_interrupted_lease_audited_without_resetting_other_records_or_retry_storm(tmp_path):
    run(tmp_path, [channel('FR')])
    with epg.database(tmp_path) as conn:
        conn.execute("UPDATE epg_source_discovery_jobs SET state='probing',lease_until=?,next_retry=?", (NOW, NOW + 3600))
        conn.commit()
    result = run(tmp_path, [channel('FR')], NOW + 10, lambda _: pytest.fail('interruption retains cooldown'))
    assert result['attemptedSources'] == 0 and result['jobStates'] == {'failed': 1}
    assert any(r['event'] == 'interrupted' for r in rows(tmp_path, 'epg_source_discovery_audit'))
    assert len(rows(tmp_path, 'source_identities')) == 1


def test_source_configuration_drift_fails_closed_preserving_prior_health(tmp_path):
    run(tmp_path, [channel('FR')])
    with epg.database(tmp_path) as conn:
        conn.execute("UPDATE source_health SET configuration='{}'")
        conn.commit()
    result = run(tmp_path, [channel('FR')], NOW + 3600, lambda _: pytest.fail('immutable config mismatch'))
    assert result['safeError'] == 'source_configuration_changed'
    assert result['jobStates'] == {'manual_review': 1}


def test_existing_source_retry_survives_queue_restart_without_false_attempt(tmp_path):
    source = worker.source_for('FR')
    epg.probe_batch(tmp_path, [source], NOW, lambda _: (payload('FR'), {}))
    result = run(tmp_path, [channel('FR')], NOW + 60, lambda _: pytest.fail('existing source cache'))
    assert result['attemptedSources'] == 0
    assert rows(tmp_path, 'epg_source_discovery_jobs')[0]['next_retry'] == NOW + 3600


def test_shared_provider_backoff_keeps_unrelated_sources_independent(tmp_path):
    def limited(_):
        raise epg.EpgError('http_429', 7200)
    run(tmp_path, [channel('FR')], fetcher=limited)
    unrelated = {'id': 'unrelated', 'url': 'https://example.org/guide.xml',
        'refreshSeconds': 21600, 'publicationAllowed': False, 'dataLicense': {'status': 'unverified'}}
    calls = []
    result = epg.probe_batch(tmp_path, [unrelated], NOW + 60,
        lambda source: (calls.append(source['id']) or b'bad xml', {}))
    assert result['attemptedSources'] == 1 and calls == ['unrelated']


@pytest.mark.parametrize('country', list(worker.CALENDARS))
def test_each_fixed_country_configuration_passes_existing_registry_validation(tmp_path, country):
    path = tmp_path / 'sources.json'
    path.write_text(json.dumps({'schemaVersion': 1, 'sources': [worker.source_for(country)]}))
    assert epg.registry(path)[0]['url'] == worker.API
    assert epg.registry(path)[0]['publicationAllowed'] is False


def test_arbitrary_country_or_url_not_accepted():
    with pytest.raises(epg.EpgError, match='unsupported_discovery_country'):
        worker.source_for('FR&url=http://127.0.0.1')


@pytest.mark.parametrize('country', ['FR', 'DE'])
def test_explicit_country_data_license_does_not_approve_mapping_or_store_programmes(tmp_path, country):
    import epg_store as store
    import epg_discovery as discovery
    run(tmp_path, [channel(country)])
    with epg.database(tmp_path) as conn:
        store.migrate(conn)
        source = worker.source_for(country)
        credit = {'sourceLabel': 'TVmaze', 'attributionUrl': 'https://www.tvmaze.com/',
            'licenseUrl': 'https://creativecommons.org/licenses/by-sa/4.0/',
            'modificationNotice': 'TVmaze episode facts normalized to UTC; no schedule gaps filled.',
            'shareAlikeRequired': True}
        store.approve_data_use(conn, source['id'], source_url=worker.API,
            evidence_url='https://www.tvmaze.com/api', data_license='CC BY-SA 4.0',
            programme_data_permission=True, attribution=credit, now=NOW)
        assert store.reviewed_data_use(conn, source['id'])['dataLicense'] == 'CC BY-SA 4.0'
        _, ids, names = discovery.source_index(conn, NOW)
        proposals = discovery.candidates_for({'name': 'Fixture network', 'epgId': None,
            'countryCode': country, 'regionCode': None}, ids, names)
        assert proposals[0]['programmeDataRightsVerified'] is True
        assert proposals[0]['contextVerified'] is False
        assert proposals[0]['automaticallyApplied'] is False
        assert store.cache_validated_payload(conn, tmp_path, source['id'], payload(country), NOW) is False
        for table in ('epg_programmes', 'epg_source_payloads', 'epg_mapping_approvals', 'epg_publication_audit'):
            assert conn.execute('SELECT count(*) FROM ' + table).fetchone()[0] == 0
