import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parents[1]))
from catalog_inventory import database, ingest, ingest_events
from process_channel_inventory import process
from test_channel_merge import seed, merge, URLS
from test_shared_catalog_events import snapshot


def transfer(n=100, **values):
    return {'id': format(n, '032x'), 'kind': 'transfer', 'url': URLS[0],
            'targetUrl': URLS[2], 'baseRevision': 0, 'targetRevision': 0, **values}


def test_transfer_one_route_is_idempotent_and_published(tmp_path):
    seed(tmp_path)
    event = transfer()
    receipt = ingest_events([event], 'b' * 64, tmp_path)
    assert receipt['receipts'][0]['status'] == 'applied'
    assert ingest_events([event], 'b' * 64, tmp_path) == receipt
    process(tmp_path, limit=0)
    data = snapshot(tmp_path)
    target = next(c for c in data['channels'] if c['name'] == 'Third')
    assert {r['url'] for r in target['routes']} == {URLS[0], URLS[2]}
    moved = next(r for r in target['routes'] if r['url'] == URLS[0])
    assert moved['transferred'] and moved['revision'] == 1
    assert not any(c['name'] == 'News One' for c in data['channels'])
    assert len(data['channels']) == 2


def test_split_prior_merge_preserves_other_routes_health_and_provenance(tmp_path):
    seed(tmp_path)
    ingest_events([merge(), {'id': '9' * 32, 'kind': 'health',
                  'url': URLS[0], 'success': 2}], 'b' * 64, tmp_path)
    with database(tmp_path) as conn:
        before = dict(conn.execute('SELECT * FROM routes WHERE url=?', (URLS[0],)).fetchone())
    result = ingest_events([transfer(baseRevision=1)], 'c' * 64, tmp_path)
    assert result['receipts'][0]['status'] == 'applied'
    with database(tmp_path) as conn:
        moved = dict(conn.execute('SELECT * FROM routes WHERE url=?', (URLS[0],)).fetchone())
        remaining = conn.execute('SELECT name,merge_id FROM routes WHERE url=?', (URLS[1],)).fetchone()
        assert tuple(remaining) == ('Unified News', merge()['mergeId'])
        for field in ('digest', 'url', 'source', 'success_votes', 'failure_votes', 'success_at', 'blocked'):
            assert moved[field] == before[field]
        assert conn.execute('SELECT source FROM route_origins WHERE digest=?', (moved['digest'],)).fetchone()[0] == 'test'
    process(tmp_path, limit=0)
    assert {r['url'] for c in snapshot(tmp_path)['channels'] if c['name'] == 'Unified News'
            for r in c['routes']} == {URLS[1]}


def test_join_existing_merge_and_old_discovery_cannot_revert(tmp_path):
    seed(tmp_path)
    event = merge(urls=URLS[1:], url=URLS[1])
    ingest_events([event], 'b' * 64, tmp_path)
    assert ingest_events([transfer(targetUrl=URLS[1], targetRevision=1)], 'c' * 64, tmp_path)['receipts'][0]['status'] == 'applied'
    ingest([{'url': URLS[0], 'name': 'Old Name', 'group': '中国 / 北京',
             'source': 'rediscovery', 'blocked': False}], 'd' * 64, tmp_path)
    ingest_events([{'id': '8' * 32, 'kind': 'upsert', 'url': URLS[0], 'baseRevision': 1,
                   'metadata': {'name': 'Old Name', 'group': '中国 / 北京', 'source': 'old'}}], 'd' * 64, tmp_path)
    process(tmp_path, limit=0)
    channels = snapshot(tmp_path)['channels']
    assert len(channels) == 1 and len(channels[0]['routes']) == 3
    assert channels[0]['mergeId'] == event['mergeId']


def test_conflict_in_either_revision_writes_nothing(tmp_path):
    seed(tmp_path)
    for n, change in enumerate([{'baseRevision': 1}, {'targetRevision': 1}], 200):
        receipt = ingest_events([transfer(n, **change)], 'b' * 64, tmp_path)['receipts'][0]
        assert receipt['status'] == 'conflict'
    with database(tmp_path) as conn:
        assert conn.execute('SELECT sum(transferred) FROM routes').fetchone()[0] == 0


def test_retired_target_or_source_cannot_be_revived(tmp_path):
    seed(tmp_path)
    ingest_events([{'id': '7' * 32, 'kind': 'retire', 'url': URLS[0]}], 'a' * 64, tmp_path)
    assert ingest_events([transfer(baseRevision=1)], 'b' * 64, tmp_path)['receipts'][0]['status'] == 'conflict'
    assert ingest_events([transfer(201, url=URLS[1], targetUrl=URLS[0], targetRevision=1)], 'b' * 64, tmp_path)['receipts'][0]['status'] == 'conflict'
    with database(tmp_path) as conn:
        assert conn.execute('SELECT blocked FROM routes WHERE url=?', (URLS[0],)).fetchone()[0] == 1


def test_unknown_route_retries_after_inventory_arrives(tmp_path):
    seed(tmp_path)
    url = 'https://media.example.org/new.m3u8'
    event = transfer(url=url)
    assert ingest_events([event], 'b' * 64, tmp_path)['receipts'][0]['status'] == 'retry'
    ingest([{'url': url, 'name': 'Different TV', 'group': '其他', 'source': 'new',
             'blocked': False}], 'a' * 64, tmp_path)
    assert ingest_events([event], 'b' * 64, tmp_path)['receipts'][0]['status'] == 'applied'


def test_invalid_transfer_is_rejected(tmp_path):
    seed(tmp_path)
    for n, change in enumerate([{'targetUrl': URLS[0]}, {'targetUrl': 'http://127.0.0.1/private'},
                                {'baseRevision': True}, {'targetRevision': -1}], 300):
        assert ingest_events([transfer(n, **change)], 'b' * 64, tmp_path)['receipts'][0]['status'] == 'rejected'
