import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parents[1]))
from fastapi import FastAPI
from fastapi.testclient import TestClient
import server_jobs as jobs
import server_worker as worker
from catalog_inventory import database as inventory_db, ingest_events


def client(tmp_path, monkeypatch):
    monkeypatch.setattr(jobs, 'DATA', tmp_path)
    monkeypatch.setattr(worker, 'DATA', tmp_path)
    app = FastAPI()
    app.include_router(jobs.router)
    return TestClient(app)


def test_queue_fast_idempotent_and_secret_free(tmp_path, monkeypatch):
    api = client(tmp_path, monkeypatch)
    body = {'kind':'category', 'inputs':[{'name':'NRBTV'}]}
    first = api.post('/api/v1/server-tasks', json=body)
    assert first.status_code == 202
    assert api.post('/api/v1/server-tasks', json=body).json() == first.json()
    assert api.get('/api/v1/server-tasks/'+first.json()['id']).json()['state'] == 'queued'
    with jobs.database() as conn:
        assert conn.execute('SELECT count(*) FROM jobs').fetchone()[0] == 1
    body['apiKey'] = 'not-accepted'
    assert api.post('/api/v1/server-tasks', json=body).status_code == 422
    assert api.get('/api/v1/server-tasks/status').json()['aiAvailable'] is False


def test_worker_classification_roundtrip(tmp_path, monkeypatch):
    api = client(tmp_path, monkeypatch)
    monkeypatch.setattr(worker, 'config', lambda: {'baseUrl':'https://ai.example.org/v1','apiKey':'hidden','model':'test'})
    monkeypatch.setattr(worker, 'ai_healthy', lambda: True)
    worker.write_state(tmp_path/'server-ai-health.json', {'lastSuccess':int(__import__('time').time())})
    monkeypatch.setattr(worker, 'ai', lambda *args: {'items':[
        {'index':0,'category':'北京','confidence':.2},
        {'index':1,'category':'青海','confidence':.95},
        {'index':2,'category':'invalid','confidence':1},
    ]})
    body = {'kind':'category','inputs':[{'name':'NRBTV'},{'name':'Qinghai'},{'name':'Unknown'}]}
    identity = api.post('/api/v1/server-tasks',json=body).json()['id']
    worker.run()
    result = api.get('/api/v1/server-tasks/'+identity).json()
    assert result['state'] == 'done'
    assert result['items'] == [{'index':1,'category':'青海','confidence':.95}]
    assert api.get('/api/v1/server-tasks/status').json()['aiAvailable'] is True


def test_candidates_quarantined_and_retirement_preserved(tmp_path, monkeypatch):
    client(tmp_path, monkeypatch)
    url = 'https://media.example.org/live.m3u8'
    monkeypatch.setattr(worker, 'probe', lambda _: True)
    row = {'name':'TV','url':url,'group':'中国 / 央视'}
    assert worker.remember_candidates([row], 'github provenance') == []
    assert worker.remember_candidates([row], 'other github provenance') == []
    import sqlite3
    with sqlite3.connect(tmp_path/'discovery_candidates.sqlite3') as conn:
        assert conn.execute('SELECT count(*) FROM candidates').fetchone()[0] == 1
        assert conn.execute('SELECT count(*) FROM candidate_origins').fetchone()[0] == 2
    with inventory_db(tmp_path) as conn:
        assert conn.execute('SELECT count(*) FROM routes').fetchone()[0] == 0
    assert len(worker.remember_candidates([row], 'reviewed provenance', True)) == 1
    ingest_events([{'id':'a'*32,'kind':'retire','url':url}], 'b'*64, tmp_path)
    # Use actual shared tombstone fields, including permanent deletion.
    with inventory_db(tmp_path) as conn:
        conn.execute('UPDATE routes SET blocked=1,deleted=1')
    assert worker.remember_candidates([row], 'rediscovered', True) == []


def test_reject_arbitrary_remote_documents(tmp_path, monkeypatch):
    client(tmp_path, monkeypatch)
    import pytest
    with pytest.raises(ValueError): worker.github_document('http://127.0.0.1/private')
    api = client(tmp_path, monkeypatch)
    assert api.post('/api/v1/server-tasks', json={'kind':'discover','inputs':[{'name':'X','url':'http://localhost'}]}).status_code == 422


def test_ai_rejects_http_before_sending_credentials(monkeypatch):
    import pytest
    def forbidden_fetch(*args, **kwargs):
        raise AssertionError('No request may be sent')
    monkeypatch.setattr(worker, 'fetch', forbidden_fetch)
    for endpoint in ('http://ccnode.briconbric.com:49530/v1',
                     'http://127.0.0.1:49530/v1',
                     'https://user:password@ccnode.briconbric.com/v1'):
        with pytest.raises(ValueError, match='HTTPS'):
            worker.ai([], 'test', {'baseUrl':endpoint,'apiKey':'hidden','model':'test'})


def test_github_tree_selection_and_exact_url_extraction(tmp_path, monkeypatch):
    client(tmp_path, monkeypatch)
    stream = 'https://media.example.org/live.m3u8'
    def github(path):
        if path.startswith('search/'): return {'items':[{'full_name':'owner/repo','default_branch':'main'}]}
        return {'tree':[{'type':'blob','size':100,'path':'unusual/folder/channel.data.txt'}]}
    monkeypatch.setattr(worker, 'github_json', github)
    monkeypatch.setattr(worker, 'github_document', lambda _: '#EXTM3U\n'+stream)
    def answer(content, *_):
        if 'paths' in content: return {'paths':['unusual/folder/channel.data.txt','invented/path']}
        return {'items':[{'name':'TV','url':stream},{'name':'Fake','url':'https://fake.example.org/live.m3u8'}]}
    monkeypatch.setattr(worker,'ai',answer)
    result=worker.discover([{'name':'TV'}],{})
    assert result[0]['documentsChecked']==1 and result[0]['published']==0
    import sqlite3
    with sqlite3.connect(tmp_path/'discovery_candidates.sqlite3') as conn:
        assert conn.execute('SELECT count(*) FROM candidates').fetchone()[0]==1


def test_concurrent_enqueue_and_claim_are_idempotent(tmp_path, monkeypatch):
    from concurrent.futures import ThreadPoolExecutor
    client(tmp_path, monkeypatch)
    with jobs.database(): pass
    with ThreadPoolExecutor(max_workers=8) as pool:
        ids = list(pool.map(lambda _: jobs.enqueue('country',[{'name':'TV'}])['id'], range(32)))
        claims = list(pool.map(lambda _: worker.claim('classification'), range(8)))
    assert len(set(ids)) == 1
    assert sum(row is not None for row in claims) == 1
    with jobs.database() as conn:
        assert conn.execute('SELECT count(*) FROM jobs').fetchone()[0] == 1
        assert conn.execute('SELECT count(*) FROM starts').fetchone()[0] == 1


def test_exhausted_kind_does_not_block_other_kinds(tmp_path, monkeypatch):
    import time
    client(tmp_path, monkeypatch)
    jobs.enqueue('category',[{'name':'First'}])
    country = jobs.enqueue('country',[{'name':'Second'}])
    discovery = jobs.enqueue('discover',[{'name':'Third'}])
    with jobs.database() as conn:
        conn.executemany('INSERT INTO starts VALUES (?,?,?)', [('x','category',int(time.time()))]*80)
    assert worker.claim('classification')['id'] == country['id']
    assert worker.claim('classification') is None
    assert worker.claim('discovery')['id'] == discovery['id']


def test_classification_cache_is_shared_across_batches(tmp_path, monkeypatch):
    client(tmp_path, monkeypatch)
    calls = []
    def answer(inputs, *_):
        calls.append(inputs)
        return {'items':[{'index':0,'country':'美国','confidence':.99}]}
    monkeypatch.setattr(worker, 'ai', answer)
    settings = {'model':'test'}
    assert worker.classify('country',[{'name':'ABC News'}], settings)[0]['country'] == '美国'
    result = worker.classify('country',[{'name':'Other'},{'name':'abc news'}], settings)
    assert len(calls) == 2 and calls[1] == [{'name':'Other'}]
    assert result[1]['index'] == 1 and result[1]['country'] == '美国'
    worker.classify('country',[{'name':'ABC News'}], settings)
    assert len(calls) == 2


def test_retry_backoff_and_logs_never_include_exception_body(tmp_path, monkeypatch):
    import time
    api = client(tmp_path, monkeypatch)
    monkeypatch.setattr(worker,'config',lambda:{'baseUrl':'https://ai.example.org/v1','apiKey':'secret','model':'test'})
    def broken(*_): raise RuntimeError('SECRET_AUTH_AND_PROMPT')
    monkeypatch.setattr(worker,'ai',broken)
    identity = jobs.enqueue('country',[{'name':'Unknown'}])['id']
    worker.run(lane='classification',limit=1)
    row = api.get('/api/v1/server-tasks/'+identity).json()
    assert row['state'] == 'queued' and row['attempts'] == 1
    assert row['nextRetryAt'] >= int(time.time()) + 55
    assert row['errorCode'] == 'internal_error'
    assert worker.claim('classification') is None
    assert 'SECRET_AUTH_AND_PROMPT' not in (tmp_path/'server-worker-classification.log').read_text()
    with jobs.database() as conn:
        conn.execute('UPDATE jobs SET attempts=2,next_attempt=0 WHERE id=?', (identity,))
    worker.run(lane='classification',limit=1)
    assert api.get('/api/v1/server-tasks/'+identity).json()['state'] == 'failed'


def test_interrupted_final_attempt_is_failed_without_losing_job(tmp_path, monkeypatch):
    client(tmp_path, monkeypatch)
    identity = jobs.enqueue('country',[{'name':'Unknown'}])['id']
    with jobs.database() as conn:
        conn.execute("UPDATE jobs SET state='running',attempts=3,updated=1 WHERE id=?", (identity,))
    assert worker.claim('classification') is None
    with jobs.database() as conn:
        row = conn.execute('SELECT * FROM jobs WHERE id=?', (identity,)).fetchone()
    assert row['state'] == 'failed' and row['error_code'] == 'worker_interrupted'


def test_status_handles_partial_heartbeat_and_shows_queue(tmp_path, monkeypatch):
    api = client(tmp_path, monkeypatch)
    (tmp_path/'server-worker-status.json').write_text('{')
    jobs.enqueue('country',[{'name':'Unknown'}])
    result = api.get('/api/v1/server-tasks/status')
    assert result.status_code == 200
    assert result.json()['workerAvailable'] is False
    assert result.json()['queue']['queued'] == 1


def test_ai_global_budget_prevents_more_upstream_calls(tmp_path, monkeypatch):
    import time
    import pytest
    client(tmp_path, monkeypatch)
    with jobs.database() as conn:
        conn.executemany('INSERT INTO ai_requests VALUES (?)', [(int(time.time()),)]*60)
    monkeypatch.setattr(worker,'fetch',lambda *_args,**_kwargs: (_ for _ in ()).throw(AssertionError('Must not call AI')))
    with pytest.raises(worker.BudgetDeferred):
        worker.ai([], 'test', {'baseUrl':'https://ai.example.org/v1','apiKey':'hidden','model':'test'})


def test_budget_defer_does_not_consume_failure_attempt(tmp_path, monkeypatch):
    api = client(tmp_path, monkeypatch)
    monkeypatch.setattr(worker,'config',lambda:{'baseUrl':'https://ai.example.org/v1','apiKey':'hidden','model':'test'})
    def deferred(*_): raise worker.BudgetDeferred()
    monkeypatch.setattr(worker,'ai',deferred)
    identity = jobs.enqueue('country',[{'name':'Unknown'}])['id']
    worker.run(lane='classification',limit=1)
    row = api.get('/api/v1/server-tasks/'+identity).json()
    assert row['state'] == 'queued' and row['attempts'] == 0
    assert row['errorCode'] == 'budget_deferred' and row['nextRetryAt']


def test_github_failure_does_not_change_verified_ai_health(tmp_path, monkeypatch):
    import time
    import urllib.error
    client(tmp_path, monkeypatch)
    monkeypatch.setattr(worker,'config',lambda:{'baseUrl':'https://ai.example.org/v1','apiKey':'hidden','model':'test'})
    worker.write_state(tmp_path/'server-ai-health.json', {'lastSuccess':int(time.time())})
    def broken(*_): raise urllib.error.HTTPError('https://api.github.com',403,'rate limited',{},None)
    monkeypatch.setattr(worker,'discover',broken)
    jobs.enqueue('discover',[{'name':'TV'}])
    worker.run(lane='discovery',limit=1)
    assert worker.ai_healthy() is True


def test_failed_ai_request_updates_health_without_exposing_details(tmp_path, monkeypatch):
    import time
    client(tmp_path, monkeypatch)
    worker.write_state(tmp_path/'server-ai-health.json', {'lastSuccess':int(time.time())})
    def broken(*_args,**_kwargs): raise ValueError('SECRET_PROVIDER_RESPONSE')
    monkeypatch.setattr(worker,'fetch',broken)
    import pytest
    with pytest.raises(ValueError):
        worker.ai([], 'test', {'baseUrl':'https://ai.example.org/v1','apiKey':'hidden','model':'test'})
    assert worker.ai_healthy() is False
    assert 'SECRET_PROVIDER_RESPONSE' not in (tmp_path/'server-ai-health.json').read_text()


def test_ambiguous_country_below_strict_threshold_remains_unknown(tmp_path, monkeypatch):
    api = client(tmp_path, monkeypatch)
    monkeypatch.setattr(worker,'ai',lambda *_: {'items':[{'index':0,'country':'澳大利亚','confidence':.83}]})
    assert worker.classify('country',[{'name':'ABC News'}],{'model':'test'}) == []
    row = jobs.enqueue('country',[{'name':'ABC News'}])
    with jobs.database() as conn:
        conn.execute("UPDATE jobs SET state='done',result=? WHERE id=?", (json.dumps([{'index':0,'country':'澳大利亚','confidence':.83}]),row['id']))
    assert api.get('/api/v1/server-tasks/'+row['id']).json()['items'] == []


def test_broken_repository_does_not_abort_other_discovery(tmp_path, monkeypatch):
    client(tmp_path, monkeypatch)
    def github(path):
        if path.startswith('search/'):
            return {'items':[{'full_name':'owner/bad','default_branch':'main'},{'full_name':'owner/good','default_branch':'main'}]}
        if 'owner/bad' in path: raise ValueError('Repository tree too large')
        return {'tree':[{'type':'blob','size':100,'path':'tv.txt'}]}
    monkeypatch.setattr(worker,'github_json',github)
    monkeypatch.setattr(worker,'github_document',lambda _: 'https://media.example.org/live.m3u8')
    monkeypatch.setattr(worker,'ai',lambda content,*_: {'paths':['tv.txt']} if 'paths' in content else {'items':[]})
    result=worker.discover([{'name':'TV'}],{})[0]
    assert result['repositoriesFailed']==1 and result['documentsChecked']==1
