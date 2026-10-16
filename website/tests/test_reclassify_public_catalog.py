from unittest.mock import patch
import io
import json
from urllib.error import HTTPError

import pytest

import reclassify_public_catalog as reclassification

from reclassify_public_catalog import ai_path, first_logo


def decision(**updates):
    item = {
        'market': '中国', 'region': '中央', 'kind': 'television',
        'programType': '综合', 'confidence': .99,
        'evidence': 'Station identity confirmed by full name and logo.',
    }
    item.update(updates)
    return item


def test_central_radio_maps_even_when_region_says_central():
    assert ai_path(decision(kind='radio', region='中央')) == ['中国', '广播']


def test_province_suffix_and_special_autonomous_region_are_normalized():
    assert ai_path(decision(region='浙江省', programType='新闻')) == ['中国', '浙江', '新闻']
    assert ai_path(decision(region='广西壮族自治区', programType='法制')) == ['中国', '广西', '法治']


def test_cctv_specialty_genres_are_representable():
    assert ai_path(decision(region='央视', programType='农业农村')) == ['中国', '央视', '农业']
    assert ai_path(decision(region='央视', programType='军事')) == ['中国', '央视', '军事']
    assert ai_path(decision(region='央视', programType='时尚')) == ['中国', '央视', '时尚']


def test_hong_kong_alias_and_english_market_are_normalized():
    assert ai_path(decision(market='香港特别行政区', region='', programType='资讯')) == [
        '国际', '香港', '新闻',
    ]


def test_uncertain_or_unmapped_decisions_remain_unclassified():
    assert ai_path(decision(confidence=.89)) is None
    assert ai_path(decision(region='火星', confidence=.99)) is None
    assert ai_path(decision(abstain=True)) is None


def test_logo_fetch_tries_next_candidate_after_a_dead_url():
    with patch('reclassify_public_catalog.logo_data', side_effect=[None, 'data:image/png;base64,ok']) as fetch:
        assert first_logo(['https://dead.example/logo.png', 'https://live.example/logo.png']) == 'data:image/png;base64,ok'
        assert fetch.call_count == 2


def target(key):
    return {
        'key': key, 'name': key, 'currentPath': ['其他'],
        'routeDigests': [key], 'routeCount': 1, 'manualCount': 0,
        'manualOnly': False, 'logoUrls': [],
        'aliases': [], 'epgId': '', 'countryCode': '', 'regionCode': '',
    }


def audit_record(key, status='classified'):
    return {'key': key, 'status': status, 'logoUsed': False}


def prepare_changed_catalog(tmp_path, monkeypatch):
    targets = [target('1' * 64), target('2' * 64)]
    monkeypatch.setattr(reclassification, 'collect_targets',
                        lambda data_dir: ({'version': 'expanded-catalog'}, targets))
    monkeypatch.setattr(reclassification, 'config', lambda: {})
    path = reclassification.result_path('progress-test', tmp_path)
    reclassification.append_results(path, [
        audit_record('9' * 64), audit_record('1' * 64),
    ])
    return path, path.read_bytes()


def test_expanded_catalog_progress_excludes_old_identities_without_erasing_audit(tmp_path, monkeypatch):
    path, original = prepare_changed_catalog(tmp_path, monkeypatch)
    monkeypatch.setattr(reclassification, 'classify_batch',
                        lambda batch, settings, data_dir: [audit_record(item['key']) for item in batch])
    status = reclassification.stage(tmp_path, 'progress-test')
    assert status['state'] == 'ready_to_apply'
    assert status['targetChannels'] == status['completedChannels'] == 2
    assert status['pendingChannels'] == 0
    assert status['classified'] == 2
    assert status['historicalAuditRecords'] == 1
    assert status['historicalAuditCounts'] == {'classified': 1}
    assert path.read_bytes().startswith(original)
    assert len(reclassification.read_results(path)) == 3


def test_budget_wait_counts_only_current_catalog_and_preserves_history(tmp_path, monkeypatch):
    path, original = prepare_changed_catalog(tmp_path, monkeypatch)

    def defer(*args, **kwargs):
        raise reclassification.BudgetDeferred()

    monkeypatch.setattr(reclassification, 'classify_batch', defer)
    monkeypatch.setattr(reclassification, 'budget_wait_seconds', lambda: 60)
    status = reclassification.stage(tmp_path, 'progress-test')
    assert status['state'] == 'waiting_for_ai_budget'
    assert status['completedChannels'] == status['pendingChannels'] == 1
    assert status['targetChannels'] == 2
    assert status['classified'] == 1
    assert status['historicalAuditRecords'] == 1
    assert status['historicalAuditCounts'] == {'classified': 1}
    assert path.read_bytes() == original


def http_error(status, headers=None, code=None):
    return HTTPError('https://ai.example.org/v1/chat/completions', status,
                     'upstream error', headers or {},
                     io.BytesIO(json.dumps({'error': {'code': code}}).encode()))


def test_upstream_retry_honors_retry_after_and_increases_backoff(monkeypatch):
    monkeypatch.setattr(reclassification.random, 'uniform', lambda *_: 0)
    assert reclassification.upstream_retry(http_error(429, {'Retry-After': '180'}), 1) == (
        'upstream_rate_limit', 180)
    assert reclassification.upstream_retry(http_error(503), 2)[1] == 60
    assert reclassification.upstream_retry(http_error(503), 100)[1] == 600
    monkeypatch.setattr(reclassification.time, 'time', lambda: 0)
    assert reclassification.upstream_retry(
        http_error(429, {'Retry-After': 'Thu, 01 Jan 1970 00:03:00 GMT'}), 1)[1] == 180


def test_quota_and_auth_errors_stop_without_repeated_requests(monkeypatch):
    assert reclassification.upstream_retry(http_error(429, code='insufficient_quota'), 1) == (
        'upstream_quota_exhausted', None)
    assert reclassification.upstream_retry(http_error(401), 1) == ('upstream_auth', None)


def test_luna_resume_retries_same_unwritten_batch_and_preserves_old_audit(tmp_path, monkeypatch):
    path, original = prepare_changed_catalog(tmp_path, monkeypatch)
    monkeypatch.setattr(reclassification, 'config', lambda: {'model': 'gpt-6-sol'})
    monkeypatch.setattr(reclassification.random, 'uniform', lambda *_: 0)
    calls, sleeps = [], []

    def classify(batch, settings, data_dir):
        calls.append(([r['key'] for r in batch], settings))
        if len(calls) == 1:
            raise http_error(429, {'Retry-After': '120'})
        return [audit_record(r['key']) for r in batch]

    monkeypatch.setattr(reclassification, 'classify_batch', classify)
    monkeypatch.setattr(reclassification.time, 'sleep', sleeps.append)
    result = reclassification.stage(tmp_path, 'progress-test', follow_budget=True,
                                    model='gpt-6-luna', upstream_limits=True)
    assert result['state'] == 'ready_to_apply'
    assert result['model'] == 'gpt-6-luna' and result['localBudgetEnforced'] is False
    assert result['completedChannels'] == 2 and result['pendingChannels'] == 0
    assert calls[0][0] == calls[1][0] == ['2' * 64]
    assert calls[0][1]['reasoningEffort'] == 'none'
    assert calls[0][1]['jsonMode'] is True
    assert sleeps == [120]
    assert path.read_bytes().startswith(original)
    assert len(reclassification.read_results(path)) == 3


def test_upstream_wait_keeps_all_progress_fields(tmp_path, monkeypatch):
    path, original = prepare_changed_catalog(tmp_path, monkeypatch)
    monkeypatch.setattr(reclassification, 'classify_batch',
                        lambda *_: (_ for _ in ()).throw(http_error(503)))
    status = reclassification.stage(tmp_path, 'progress-test', model='gpt-6-luna', upstream_limits=True)
    assert status['state'] == 'waiting_for_upstream'
    assert status['completedChannels'] + status['pendingChannels'] == status['targetChannels'] == 2
    assert status['historicalAuditRecords'] == 1
    assert status['nextRetryAt'] and status['waitSeconds'] >= 30
    assert path.read_bytes() == original


def test_auth_failure_preserves_audit_and_requires_attention(tmp_path, monkeypatch):
    path, original = prepare_changed_catalog(tmp_path, monkeypatch)
    monkeypatch.setattr(reclassification, 'classify_batch',
                        lambda *_: (_ for _ in ()).throw(http_error(403)))
    with pytest.raises(reclassification.AuditStopped, match='upstream_auth'):
        reclassification.stage(tmp_path, 'progress-test', follow_budget=True, upstream_limits=True)
    status = json.loads(path.with_suffix('.status.json').read_text())
    assert status['state'] == 'failed' and status['errorCode'] == 'upstream_auth'
    assert status['completedChannels'] == status['pendingChannels'] == 1
    assert path.read_bytes() == original


def test_new_decisions_record_model_without_changing_identity(monkeypatch):
    monkeypatch.setattr(reclassification, 'first_logo', lambda *_: None)
    monkeypatch.setattr(reclassification, 'ai', lambda *_: {'items': [dict(decision(), index=0)]})
    result = reclassification.classify_batch([target('2' * 64)], {'model': 'gpt-6-luna'})[0]
    assert result['key'] == '2' * 64 and result['model'] == 'gpt-6-luna'
    assert result['status'] == 'classified'

