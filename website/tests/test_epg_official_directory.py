from datetime import datetime
import json

from epg_auto_search import candidate_allowed
from epg_official_directory import SHANGHAI, inspect_schedule, schedule_urls


def test_edition_and_source_echo_are_verified():
    now = int(datetime(2026, 11, 28, 12, tzinfo=SHANGHAI).timestamp())
    request = {'stage': 'structured_api', 'catalogueContext': {'countryCode': 'CN', 'name': 'CCTV-5+'}}
    url, tomorrow = schedule_urls(request, now)
    assert candidate_allowed(url, ['api.cntv.cn'], request['stage'])
    assert 'c=cctv5plus' in url and 'd=20261129' in tomorrow
    response = {'data': {'cctv5plus': {'channelName': 'CCTV-5+ 体育赛事',
        'list': [{'startTime': now - 1, 'endTime': now + 1, 'title': '赛事'}]}}}
    assert inspect_schedule(url, json.dumps(response).encode(), now)['currentIntervalRecords'] == 1
    assert inspect_schedule(tomorrow, json.dumps(response).encode(), now)['validIntervalRecords'] == 0
    request['catalogueContext']['name'] = 'CCTV-4'
    assert schedule_urls(request, now) == []
    request['catalogueContext']['name'] = 'CCTV-4 (欧洲)'
    assert 'c=cctveurope' in schedule_urls(request, now)[0]
