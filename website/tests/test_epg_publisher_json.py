"""Authored public JSON schedules; no live data, credentials or approvals."""
from pathlib import Path
import sys
import json
import pytest
sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_publisher_json as adapter
import epg_evidence_review as review
import epg_schedule_worker as scheduler
from epg_ingest import EpgError
from test_epg_auto_admit import prepared, NOW, ORIGIN
from test_epg_publisher_admit import publisher_identity


def source(url=ORIGIN+'/channel.json'):
    return {'id':adapter.source_id(url, 'fixture-tv', 'Fixture TV', 'JP'), 'url':url,
            'format':'publisher-json', 'channelName':'Fixture TV', 'countryCode':'JP',
            'catalogChannelId':'fixture-tv', 'redirectUrls':[]}


def body():
    return {'response': {'title':'Fixture TV', 'schedule': {'fixture-day': [
        {'title':'Current', 'startUtc':NOW-100, 'stopUtc':NOW+3600, 'description':'must not publish'},
        {'title':'Next', 'startUtc':NOW+3600, 'stopUtc':NOW+7200}]}}}


def test_only_the_selected_channel_container_and_explicit_fields_are_used():
    data = {'channels':[body()['response'], {'title':'Other TV','schedule':[
        {'title':'Wrong channel', 'startUtc':NOW-100, 'stopUtc':NOW+2000}]}]}
    parsed = adapter.parse_schedule(json.dumps(data).encode(), source(), NOW)
    assert [p['title'] for p in parsed['programmes']] == ['Current','Next']
    assert parsed['quality']['currentAndFutureChannels'] == 1
    assert 'description' not in json.dumps(parsed)
    assert adapter.success_refresh_delay(parsed,NOW,5*86400) < 7200


def test_ambiguous_channel_and_implicit_times_do_not_create_guide():
    data = {'channels':[body()['response'],body()['response']]}
    with pytest.raises(EpgError,match='identity_ambiguous'):
        adapter.parse_schedule(json.dumps(data).encode(),source(),NOW)
    data = body(); data['response']['schedule']['fixture-day'][0]['startUtc']='2026-11-23T10:00:00'
    data['response']['schedule']['fixture-day'][1].pop('stopUtc')
    parsed = adapter.parse_schedule(json.dumps(data).encode(),source(),NOW)
    assert parsed['programmes'] == []
    with pytest.raises(EpgError,match='rolling_request'):
        adapter.validate_source(source(ORIGIN+'/channel.json?date=20261123'))


def test_common_json_schedule_reaches_automatic_real_ingestion(prepared,tmp_path):
    publisher_identity(prepared)
    url=ORIGIN+'/channel.json'
    evidence={'technicalCheck':{'httpStatus':200,'contentType':'application/json'}}
    with prepared:
        prepared.execute('UPDATE epg_research_source_candidates SET url=?,evidence=?',(url,json.dumps(evidence)))
    metadata={'sourceUrl':url,'finalUrl':url}
    receipt=review.validate_one_source(prepared,tmp_path,NOW,
        fetcher=lambda _:(json.dumps(body()).encode(),metadata))
    assert receipt['newMappings'] == receipt['newGrants'] == 1
    assert receipt['rawProgrammeCacheGranted']
    assert scheduler.run(tmp_path,now=NOW)['changedChannels'] == 1
    assert prepared.execute('SELECT count(*) FROM epg_programmes').fetchone()[0] == 2
