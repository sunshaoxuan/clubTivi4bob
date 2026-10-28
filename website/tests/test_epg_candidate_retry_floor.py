"""A server-owned candidate retry queue, without any live provider requests."""
import json

import pytest

from test_epg_ingest import NOW, SOURCE, xml
import epg_ingest as epg


def candidate():
    return next(source for source in epg.registry()
        if source['id']=='frikanalen-official-diagnostic-v1')


def test_candidate_is_fixed_origin_diagnostic_with_no_publication_grant():
    source=candidate()
    assert source['url']=='https://frikanalen.no/xmltv/upcoming/'
    assert source['format']=='xmltv' and source['redirectUrls']==[]
    assert source['calendarTimezone']=='Europe/Oslo'
    assert source['minimumRetrySeconds']==source['refreshSeconds']==3600
    assert source['publicationAllowed'] is False
    assert source['dataLicense']['status']=='aggregator_use_evidence_found_not_granted'


@pytest.mark.parametrize('value',[None,True,'3600',0,899,3601,86401])
def test_invalid_retry_floor_rejected(tmp_path,value):
    source={**SOURCE,'refreshSeconds':3600,'minimumRetrySeconds':value}
    path=tmp_path/'registry.json'
    path.write_text(json.dumps({'schemaVersion':1,'sources':[source]}))
    with pytest.raises(epg.EpgError,match='invalid_minimum_retry_interval'):
        epg.registry(path)


@pytest.mark.parametrize('retry_after',[0,7200])
def test_floor_and_longer_retry_after_are_durable_without_early_request(tmp_path,retry_after):
    source=candidate()
    def fail(_):
        raise epg.EpgError('http_502',retry_after=retry_after)
    first=epg.probe_batch(tmp_path,[source],NOW,fail)['sources'][0]
    assert first['state']=='failed'
    assert first['next_retry']>=NOW+max(3600,retry_after)
    assert epg.probe_batch(tmp_path,[source],first['next_retry']-1,
        lambda _:pytest.fail('candidate retry must respect the durable deadline'))['attemptedSources']==0
    with epg.database(tmp_path) as conn:
        assert conn.execute('SELECT count(*) FROM source_identities').fetchone()[0]==0


def test_interrupted_candidate_keeps_one_hour_floor_and_other_source_can_run(tmp_path):
    source=candidate()
    class SimulatedInterruption(BaseException):
        pass
    def interrupted(_):
        raise SimulatedInterruption()
    with pytest.raises(SimulatedInterruption):
        epg.probe_batch(tmp_path,[source],NOW,interrupted)
    with epg.database(tmp_path) as conn:
        receipt=dict(conn.execute('SELECT * FROM source_health').fetchone())
    assert receipt['state']=='probing' and receipt['next_retry']>=NOW+3600
    calls=[]
    other={**SOURCE,'id':'unrelated'}
    result=epg.probe_batch(tmp_path,[source,other],NOW+60,
        lambda s:(calls.append(s['id']) or xml(),{}))
    assert calls==['unrelated'] and result['attemptedSources']==1


def test_success_remains_metadata_only_without_approved_mapping_and_grant(tmp_path):
    source=candidate()
    result=epg.probe_batch(tmp_path,[source],NOW,lambda _:(xml(),{}))
    assert result['sources'][0]['state']=='healthy' and result['published'] is False
    assert result['sources'][0]['next_retry']==NOW+3600
    with epg.database(tmp_path) as conn:
        assert conn.execute('SELECT count(*) FROM source_identities').fetchone()[0]==1
        for table in ('epg_data_grants','epg_mapping_approvals','epg_programmes',
                      'epg_source_payloads','epg_publication_audit'):
            exists=conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",(table,)).fetchone()
            assert not exists or conn.execute('SELECT count(*) FROM '+table).fetchone()[0]==0
    assert not list(tmp_path.rglob('*.xml')) and not list(tmp_path.rglob('*.gz'))
