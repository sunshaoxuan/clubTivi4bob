import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))
from catalog_inventory import database, ingest, ingest_events
from route_identity import canonical_route_url
from process_channel_inventory import process


def route(url, source='GitHub A', blocked=False):
    return dict(url=url, name='CCTV-5+', group='中国 / 央视',
                source=source, blocked=blocked)


def test_conservative_identity():
    assert canonical_route_url('HTTP://MEDIA.EXAMPLE.ORG:80/live.m3u8?a=1&b=2') == 'http://media.example.org/live.m3u8?a=1&b=2'
    assert canonical_route_url('https://MEDIA.EXAMPLE.ORG:443') == 'https://media.example.org/'
    for url in ('https://media.example.org/live.m3u8?b=2&a=1',
                'https://media.example.org/LIVE.m3u8',
                'http://media.example.org:8080/live.m3u8',
                'https://media.example.org/live%2fm3u8?',
                'https://[2606:4700:4700::1111]/live.m3u8'):
        assert canonical_route_url(url) == url


def test_cross_provider_ingest_and_retirement_are_idempotent(tmp_path):
    original = 'https://MEDIA.EXAMPLE.ORG:443/live.m3u8'
    canonical = 'https://media.example.org/live.m3u8'
    assert ingest([route(original), route(canonical, 'GitHub B')], 'a'*64, tmp_path)['storedRoutes'] == 1
    process(tmp_path, verifier=lambda _: True)
    first = ingest_events([dict(id='1'*32, kind='retire', url=original)], 'b'*64, tmp_path)
    again = ingest_events([dict(id='2'*32, kind='retire', url=canonical)], 'c'*64, tmp_path)
    assert first['receipts'][0]['revision'] == again['receipts'][0]['revision'] == 1
    ingest([route(original), route(canonical, 'GitHub C')], 'd'*64, tmp_path)
    with database(tmp_path) as conn:
        row = conn.execute('SELECT * FROM routes').fetchone()
        assert row['url'] == canonical and row['blocked'] == 1
        assert conn.execute('SELECT count(*) FROM routes').fetchone()[0] == 1
        assert {r[0] for r in conn.execute('SELECT source FROM route_origins')} == {'GitHub A', 'GitHub B', 'GitHub C'}
    process(tmp_path, limit=0)
    import gzip, json
    manifest = json.loads((tmp_path/'channel-catalog/manifest.json').read_text())
    payload = json.loads(gzip.decompress((tmp_path/'channel-catalog/snapshots'/f"{manifest['sha256']}.json.gz").read_bytes()))
    assert payload['channels'] == []


def test_legacy_duplicates_merge_without_losing_tombstones_or_manual_category(tmp_path):
    canonical = 'https://media.example.org/live.m3u8'
    variants = [canonical, 'https://MEDIA.EXAMPLE.ORG:443/live.m3u8']
    with database(tmp_path) as conn:
        for i, url in enumerate(variants):
            conn.execute('INSERT INTO routes(digest,name,url,group_name,source,blocked,received,manual_category,revision,success_votes) VALUES(?,?,?,?,?,?,?,?,?,?)',
                (hashlib.sha256(url.encode()).hexdigest(), 'CCTV-5+', url,
                 '中国 / 央视' if i == 0 else '其他', f'provider{i}', i, 100+i, int(i == 0), 4-i, 2+i))
        conn.execute("DELETE FROM catalog_migrations WHERE name='route_identity_v1'")
    with database(tmp_path) as conn:
        rows = conn.execute('SELECT * FROM routes').fetchall()
        assert len(rows) == 1
        row = rows[0]
        assert row['url'] == canonical and row['blocked'] == 1
        assert row['manual_category'] == 1 and row['group_name'] == '中国 / 央视'
        assert row['success_votes'] == 5 and row['revision'] == 5
    with database(tmp_path) as conn:
        assert conn.execute('SELECT success_votes FROM routes').fetchone()[0] == 5


def test_same_name_different_signals_stay_separate(tmp_path):
    urls = ['https://media.example.org/a.m3u8', 'https://media.example.org/b.m3u8',
            'https://media.example.org/a.m3u8?channel=2']
    assert ingest([route(url) for url in urls], 'a'*64, tmp_path)['storedRoutes'] == 3
