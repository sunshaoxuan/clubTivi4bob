import hashlib
import json
from pathlib import Path
import subprocess
import sys
import urllib.error

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).parents[1]))
import channel_route_recovery as recovery
import route_recovery_search as search
import server_jobs
from catalog_inventory import database, ingest
from process_channel_inventory import process

OLD = 'https://media.example.org/old.m3u8'
NEW = 'https://media.example.org/new.m3u8'
SOURCE = 'https://publisher.example.org/MY.m3u'


@pytest.fixture
def target(tmp_path):
    ingest([{'name': 'Astro AEC', 'url': OLD, 'group': '国际 / 马来西亚 / 电视 / 综合',
             'source': 'reviewed', 'blocked': False, 'playableAt': None}], 'a' * 64, tmp_path)
    process(tmp_path, verifier=lambda _: True)
    _, payload = recovery.catalog(tmp_path)
    channel = payload['channels'][0]
    return channel


def profile_for(tmp_path, channel):
    _, payload = recovery.catalog(tmp_path)
    return {'channelId': channel['id'], 'metadataHash': recovery.identity(payload, channel, include_routes=False),
        'identityVerified': True, 'publicationAllowed': True, 'operator': 'Test broadcaster',
        'countryCode': 'MY', 'channelNumber': '306', 'language': 'Mandarin',
        'feedVariant': 'Malaysia', 'broadcastType': 'television',
        'identityEvidenceUrls': ['https://publisher.example.org/channel'],
        'authorizationEvidenceUrls': ['https://publisher.example.org/media-terms'],
        'approvedDocuments': [SOURCE], 'mediaHosts': ['media.example.org']}


def candidate(url=NEW):
    return {'url': url, 'name': 'Astro AEC', 'source': SOURCE, 'countryCode': 'MY', 'decoded': True}


def profile_path(tmp_path, profile):
    path = tmp_path / 'profiles.json'
    path.write_text(json.dumps({'schemaVersion': 1, 'channels': [profile]}))
    return path


def test_exact_identity_and_idempotent_persistent_retry(tmp_path, target):
    first = recovery.enqueue(target['id'], OLD, tmp_path, 100)
    with server_jobs.database(tmp_path) as conn:
        conn.execute('UPDATE jobs SET next_attempt=9999,attempts=4 WHERE id=?', (first['id'],))
    again = recovery.enqueue(target['id'], OLD, tmp_path, 200)
    assert again['next_attempt'] == 9999 and again['attempts'] == 4
    with pytest.raises(ValueError, match='mismatch'):
        recovery.enqueue(target['id'], NEW, tmp_path)
    with pytest.raises(ValueError, match='public_channel_required'):
        recovery.enqueue('same-name-other-country', OLD, tmp_path)
    with database(tmp_path) as conn:
        conn.execute('UPDATE routes SET blocked=1,deleted=1')
    with pytest.raises(ValueError, match='retired'):
        recovery.enqueue(target['id'], OLD, tmp_path)


def test_server_seeds_last_failed_route_without_client_search(tmp_path, target):
    assert recovery.seed(tmp_path, 1000) == []
    with database(tmp_path) as conn:
        row = conn.execute('SELECT * FROM routes').fetchone()
        recovery.record_failure_signal(conn, row, {'failure': 1, 'observation': 'manual'}, 1000)
    assert recovery.seed(tmp_path, 1000) == []
    with database(tmp_path) as conn:
        recovery.record_failure_signal(conn, conn.execute('SELECT * FROM routes').fetchone(),
                                       {'failure': 1, 'observation': 'stall'}, 1000)
    assert len(recovery.seed(tmp_path, 1000)) == 1
    assert recovery.seed(tmp_path, 1001) == []


def test_one_healthy_alternative_does_not_seed(tmp_path, target):
    profile = profile_for(tmp_path, target)
    _, payload = recovery.catalog(tmp_path)
    recovery.admit(tmp_path, recovery.identity(payload, target), target['id'], [candidate()], profile, 100)
    with database(tmp_path) as conn:
        conn.execute('UPDATE routes SET failures=2,checked_at=1000 WHERE url=?', (OLD,))
    assert recovery.seed(tmp_path, 1001) == []


@pytest.mark.parametrize('mutation', [
    {'publicationAllowed': False}, {'identityVerified': False}, {'authorizationEvidenceUrls': []},
    {'authorizationEvidenceUrls': ['http://127.0.0.1/grant']}, {'feedVariant': ''},
    {'countryCode': 'US'}, {'broadcastType': 'unknown'}, {'mediaHosts': ['other.example.org']},
    {'approvedDocuments': ['https://other.example.org/MY.m3u']},
])
def test_identity_and_media_permission_gate(tmp_path, target, mutation):
    profile = {**profile_for(tmp_path, target), **mutation}
    assert not recovery.can_publish(profile, candidate())


def test_same_identity_publish_survives_ordinary_refresh_and_is_idempotent(tmp_path, target):
    profile = profile_for(tmp_path, target)
    _, payload = recovery.catalog(tmp_path)
    hashed = recovery.identity(payload, target)
    result = recovery.admit(tmp_path, hashed, target['id'], [candidate()], profile, 100)
    assert result['added'] == 1
    _, updated = recovery.catalog(tmp_path)
    assert len(updated['channels']) == 1
    assert updated['channels'][0]['id'] == target['id']
    assert {r['url'] for r in updated['channels'][0]['routes']} == {OLD, NEW}
    assert recovery.admit(tmp_path, recovery.identity(updated, updated['channels'][0]), target['id'],
                          [candidate()], profile, 101)['added'] == 0
    process(tmp_path, limit=0)
    _, refreshed = recovery.catalog(tmp_path)
    assert len(refreshed['channels']) == 1
    assert refreshed['channels'][0]['id'] == target['id']
    assert {r['url'] for r in refreshed['channels'][0]['routes']} == {OLD, NEW}
    with database(tmp_path) as conn:
        assert conn.execute('SELECT count(*) FROM routes').fetchone()[0] == 2


def test_failed_publication_rolls_back_inventory_and_manifest(tmp_path, target, monkeypatch):
    manifest, payload = recovery.catalog(tmp_path)
    profile = profile_for(tmp_path, target)
    publish = recovery.publish
    def broken(payload, directory):
        publish(payload, directory)
        raise OSError('simulated post-manifest failure')
    monkeypatch.setattr(recovery, 'publish', broken)
    with pytest.raises(OSError):
        recovery.admit(tmp_path, recovery.identity(payload, target), target['id'], [candidate()], profile, 100)
    assert recovery.catalog(tmp_path)[0] == manifest
    with database(tmp_path) as conn:
        assert conn.execute('SELECT count(*) FROM routes').fetchone()[0] == 1


def test_deployed_persistent_matcher_binding_is_compatible_and_never_reassigned(tmp_path, target):
    with database(tmp_path) as conn:
        conn.execute('CREATE TABLE catalog_channels (id TEXT PRIMARY KEY,metadata TEXT)')
        conn.execute('CREATE TABLE catalog_channel_routes (digest TEXT PRIMARY KEY,channel_id TEXT,state TEXT,reason TEXT,signature TEXT)')
        conn.execute('INSERT INTO catalog_channels VALUES(?,?)', (target['id'], json.dumps(target)))
    profile = profile_for(tmp_path, target)
    _, payload = recovery.catalog(tmp_path)
    assert recovery.admit(tmp_path, recovery.identity(payload, target), target['id'], [candidate()], profile, 100)['added'] == 1
    with database(tmp_path) as conn:
        row = conn.execute('SELECT * FROM catalog_channel_routes').fetchone()
        assert row['digest'] == hashlib.sha256(NEW.encode()).hexdigest()
        assert row['channel_id'] == target['id'] and row['state'] == 'assigned'
        assert row['reason'] == 'reviewed-route-recovery'


def test_metadata_drift_and_tombstone_block_admission(tmp_path, target):
    profile = profile_for(tmp_path, target)
    _, payload = recovery.catalog(tmp_path)
    hashed = recovery.identity(payload, target)
    ingest([{'name': 'Other', 'url': NEW, 'group': '国际 / 马来西亚',
             'source': 'manual', 'blocked': True, 'playableAt': None}], 'b' * 64, tmp_path)
    assert recovery.admit(tmp_path, hashed, target['id'], [candidate()], profile, 100)['added'] == 0
    payload['channels'][0]['name'] = 'Other regional feed'
    payload['version'] = 'changed'
    recovery.publish(payload, tmp_path)
    with pytest.raises(ValueError, match='identity_changed'):
        recovery.admit(tmp_path, hashed, target['id'], [candidate()], profile, 101)


def test_retry_no_candidates_then_recovery_and_public_receipt(tmp_path, target):
    profile = profile_for(tmp_path, target)
    path = profile_path(tmp_path, profile)
    job = recovery.enqueue(target['id'], OLD, tmp_path, 1000)
    findings = {'queries': ['exact Astro AEC MY'], 'sources': [{'url': SOURCE, 'state': 'checked'}], 'candidates': []}
    result = recovery.run(tmp_path, now=1000, profile_path=path, search=lambda *_: findings)
    assert result['jobs'][0]['state'] == 'no_candidates'
    retry = result['jobs'][0]['nextRetryAt']
    assert retry == 2800
    assert recovery.run(tmp_path, now=1001, profile_path=path, search=lambda *_: pytest.fail())['processed'] == 0
    findings['candidates'] = [candidate()]
    result = recovery.run(tmp_path, now=retry, profile_path=path, search=lambda *_: findings, decoder=lambda *_: True)
    assert result['jobs'][0]['added'] == 1
    with server_jobs.database(tmp_path) as conn:
        row = conn.execute('SELECT * FROM jobs WHERE id=?', (job['id'],)).fetchone()
        public = server_jobs.public_result(row)
        assert public['state'] == 'done'
        assert 'queries' not in json.dumps(public) and 'publisher.example.org' not in json.dumps(public)
        assert conn.execute('SELECT count(*) FROM route_recovery_audit').fetchone()[0] == 3


def test_missing_permission_never_decodes_or_admits(tmp_path, target):
    recovery.enqueue(target['id'], OLD, tmp_path, 1000)
    path = profile_path(tmp_path, {**profile_for(tmp_path, target), 'publicationAllowed': False})
    result = recovery.run(tmp_path, now=1000, profile_path=path, search=lambda *_: {'candidates': [candidate()]},
                          decoder=lambda *_: pytest.fail('unapproved media must not be fetched'))
    assert result['jobs'][0]['state'] == 'needs_review'
    assert result['jobs'][0]['decisions'][0]['decision'] == 'identity_or_media_permission_unverified'


def test_search_failure_and_upstream_wait_are_not_no_candidates(tmp_path, target):
    recovery.enqueue(target['id'], OLD, tmp_path, 1000)
    path = profile_path(tmp_path, profile_for(tmp_path, target))
    result = recovery.run(tmp_path, now=1000, profile_path=path,
                          search=lambda *_: {'sources': [{'state': 'unavailable'}]})
    assert result['jobs'][0]['errorCode'] == 'search_sources_unavailable'
    def limited(*_):
        raise search.SearchDeferred('search_upstream_rate_limit', 10000)
    result = recovery.run(tmp_path, now=2800, profile_path=path, search=limited)
    assert result['jobs'][0]['nextRetryAt'] == 10000


def test_interrupted_lease_and_hourly_admission_are_bounded(tmp_path, target):
    job = recovery.enqueue(target['id'], OLD, tmp_path, 1000)
    assert recovery.claim(tmp_path, 1000)['attempts'] == 1
    assert recovery.claim(tmp_path, 1100) is None
    assert recovery.claim(tmp_path, 1200) is None
    assert recovery.claim(tmp_path, 1500)['attempts'] == 2
    with server_jobs.database(tmp_path) as conn:
        conn.execute("UPDATE jobs SET state='queued',next_attempt=0 WHERE id=?", (job['id'],))
        for index in range(4):
            conn.execute('INSERT INTO starts VALUES(?,?,?)', (str(index), 'recover', 1500))
    assert recovery.claim(tmp_path, 1501) is None


def test_full_inbox_keeps_consuming_and_backoff_cannot_starve_new_targets(tmp_path, target, monkeypatch):
    ingest([{'name': 'Other Malaysia channel', 'url': NEW, 'group': '国际 / 马来西亚 / 电视 / 综合',
             'source': 'reviewed', 'blocked': False, 'playableAt': None}], 'b' * 64, tmp_path)
    process(tmp_path, verifier=lambda _: True)
    with database(tmp_path) as conn:
        conn.execute('UPDATE routes SET failures=1,checked_at=1000')
    old = recovery.enqueue(target['id'], OLD, tmp_path, 1000)
    monkeypatch.setattr(recovery, 'MAX_QUEUE', 1)
    path = profile_path(tmp_path, profile_for(tmp_path, target))
    result = recovery.run(tmp_path, now=1000, profile_path=path, search=lambda *_: {'candidates': []})
    assert result['processed'] == 1 and result['jobs'][0]['id'] == old['id']
    # The waiting retry no longer occupies a ready-inbox slot.
    assert len(recovery.seed(tmp_path, now=1001)) == 1
    # Both lanes get a turn: due retry, then the untouched target. Fresh-failure
    # floods and repeatedly failing old targets cannot starve each other.
    retry = recovery.claim(tmp_path, 5000)
    assert retry['id'] == old['id'] and retry['attempts'] == 2
    next_job = recovery.claim(tmp_path, 5001)
    assert next_job['id'] != old['id'] and next_job['attempts'] == 1


def test_legacy_queue_budget_is_separate_from_route_recovery(tmp_path, target, monkeypatch):
    monkeypatch.setattr(server_jobs, 'DATA', tmp_path)
    monkeypatch.setattr(recovery, 'MAX_QUEUE', 1)
    legacy = server_jobs.enqueue('category', [{'name': 'Existing classification'}])
    route = recovery.enqueue(target['id'], OLD, tmp_path, 1000)
    assert route['id'] != legacy['id']
    assert server_jobs.enqueue('country', [{'name': 'Another classification'}])['state'] == 'queued'


def test_api_uses_exact_catalog_identity_and_keeps_audit_private(tmp_path, target, monkeypatch):
    monkeypatch.setattr(server_jobs, 'DATA', tmp_path)
    app = FastAPI()
    app.include_router(server_jobs.router)
    api = TestClient(app)
    body = {'kind': 'recover', 'inputs': [{'channelId': target['id'], 'failedUrl': OLD}]}
    response = api.post('/api/v1/server-tasks', json=body)
    assert response.status_code == 202
    assert api.post('/api/v1/server-tasks', json=body).json() == response.json()
    body['inputs'][0]['failedUrl'] = 'https://unrelated.example.org/live'
    assert api.post('/api/v1/server-tasks', json=body).status_code == 422
    assert api.post('/api/v1/server-tasks', json={'kind': 'recover', 'inputs': [{'name': 'Astro AEC'}]}).status_code == 422
    assert api.get('/api/v1/server-tasks/' + response.json()['id']).headers['cache-control'] == 'no-store'


def test_candidate_names_country_variant_and_secret_filter():
    channel = {'name': 'CCTV-5+', 'countryCode': 'CN'}
    text = '''#EXTM3U
#EXTINF:-1 tvg-country="CN",CCTV-5
https://media.example.org/wrong.m3u8
#EXTINF:-1 tvg-country="US",CCTV-5+
https://media.example.org/foreign.m3u8
#EXTINF:-1 tvg-country="CN",CCTV-5+1
https://media.example.org/delay.m3u8
#EXTINF:-1 tvg-country="CN",CCTV-5+
https://media.example.org/private.m3u8?token=secret
#EXTINF:-1 tvg-country="CN",CCTV-5+
https://media.example.org/right.m3u8'''
    assert [c['url'] for c in search.parse_candidates(text, SOURCE, channel)] == ['https://media.example.org/right.m3u8']


@pytest.mark.parametrize('url', ['http://127.0.0.1/x', 'https://10.0.0.1/x', 'file:///etc/passwd',
                               'https://user:pass@example.org/x', 'https://example.org/x?key=secret'])
def test_unsafe_urls_fail_before_network(url):
    with pytest.raises(ValueError):
        search.read_public(url)


def test_media_decoder_requires_real_frames_and_rejects_encryption(monkeypatch):
    monkeypatch.setattr(search.shutil, 'which', lambda _: '/test/ffmpeg')
    profile = {'mediaHosts': ['media.example.org'], 'broadcastType': 'television'}
    def reader(*_, **kwargs):
        assert kwargs['allowed_hosts'] == {'media.example.org'}
        return b'G' * 512
    def execute(args, **kwargs):
        assert '-progress' in args and 'file,pipe' in args and kwargs['timeout'] == 8
        assert args[-1] == '-' and 'null' in args
        return subprocess.CompletedProcess(args, 0, stdout=b'frame=0\nprogress=end\n')
    assert search.decode_candidate(NEW, profile, reader=reader, execute=execute) is False
    assert search.decode_candidate(NEW, profile, reader=reader,
        execute=lambda args, **_: subprocess.CompletedProcess(args, 0, stdout=b'frame=3\nprogress=end\n')) is True
    assert search.decode_candidate(NEW, profile, reader=lambda *_, **__: b'#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="secret"\nsegment.ts',
                                   execute=lambda *_: pytest.fail()) is False


def test_redirect_host_is_revalidated_and_rate_limit_floor_is_retained(monkeypatch):
    class Redirect:
        def open(self, request, **_):
            raise urllib.error.HTTPError(request.full_url, 302, 'redirect', {'Location': 'http://127.0.0.1/private'}, None)
    monkeypatch.setattr(search.urllib.request, 'build_opener', lambda *_: Redirect())
    with pytest.raises(ValueError):
        search.read_public(NEW)
    class Limited:
        def open(self, request, **_):
            raise urllib.error.HTTPError(request.full_url, 429, 'limited', {'Retry-After': '172800'}, None)
    monkeypatch.setattr(search.urllib.request, 'build_opener', lambda *_: Limited())
    monkeypatch.setattr(search.time, 'time', lambda: 1000)
    with pytest.raises(search.SearchDeferred) as error:
        search.read_public(NEW)
    assert error.value.retry_at == 173800


def test_channel_scoped_github_tree_search_is_cached_and_auditable(tmp_path):
    calls = []
    def reader(url, **_):
        calls.append(url)
        if '/search?' in url: return b'<rss><channel/></rss>'
        if '/search/repositories?' in url: return b'{"items":[]}'
        if '/git/trees/' in url: return b'{"tree":[{"type":"blob","size":100,"path":"streams/my.m3u"}]}'
        if 'raw.githubusercontent' in url:
            return b'#EXTM3U\n#EXTINF:-1,Astro AEC\nhttps://media.example.org/new.m3u8\n'
        return b'{"default_branch":"main"}'
    channel = {'name': 'Astro AEC', 'countryCode': 'MY'}
    first = search.search_channel(channel, None, tmp_path, reader=reader)
    assert first['candidates'][0]['url'] == NEW
    assert any('Astro AEC' in q for q in first['queries'])
    assert all('checkedAt' in source for source in first['sources'])
    again = search.search_channel(channel, None, tmp_path, reader=lambda *_a, **_k: pytest.fail('cached source redownload'))
    assert again['candidates'] == first['candidates']
    assert all(source['state'] == 'cached' for source in again['sources'])
