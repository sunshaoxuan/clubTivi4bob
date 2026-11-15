import gzip
import hashlib
import json
from pathlib import Path
import sqlite3
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'website'))
sys.path.insert(0, str(Path(__file__).parent))

from channel_matching import profile, _evidence_profile, _market_group_allowed
from channel_reference import Reference
from market_review_admin import build_batch, apply_batch
from publish_channel_catalog import publish

URL = ('https://action-rakuten-tv-uk.fast.rakuten.tv/v1/manifest/'
       '0547f18649bd788bec7b67b746e47670f558b6b2/production-LiveChannel-6065/'
       '8e7f1d8c-5ba7-4dde-9834-b058e17f6bfe/4.m3u8')


def load(tmp):
    m = json.loads((tmp / 'channel-catalog/manifest.json').read_text())
    return m, json.loads(gzip.decompress((tmp / 'channel-catalog/snapshots' / (m['sha256'] + '.json.gz')).read_bytes()))


@pytest.fixture
def catalog(tmp_path):
    digest = hashlib.sha256(URL.encode()).hexdigest()
    c = dict(id='action', name='Action Movies', epgId='GB2600015OS', countryCode='US',
             regionCode=None, categoryId='movie', logoUrl=None, sortOrder=0)
    other = dict(c, id='other', name='Other', epgId=None)
    route = dict(id='route-' + digest[:24], url=URL, source='fixture', lastPlayableAt=None,
                 healthScore=.8, revision=4)
    categories = [dict(id='world', name='国际', parentId=None, sortOrder=0),
                  dict(id='us', name='美国', parentId='world', sortOrder=0),
                  dict(id='movie', name='电影', parentId='us', sortOrder=0)]
    publish(dict(schemaVersion=1, version='fixture', categories=categories, channels=[
        dict(c, routes=[route]), dict(other, routes=[dict(route, id='other-route', url='https://example.org/other.m3u8')])]), tmp_path)
    with sqlite3.connect(tmp_path / 'channel_inventory.sqlite3') as conn:
        conn.executescript('''
        CREATE TABLE routes(digest TEXT PRIMARY KEY,name TEXT,url TEXT,group_name TEXT,source TEXT,
          epg_id TEXT,manual_category INTEGER,manual_name INTEGER,merge_id TEXT,transferred INTEGER,
          revision INTEGER,blocked INTEGER,deleted INTEGER);
        CREATE TABLE catalog_channels(id TEXT PRIMARY KEY,metadata TEXT,group_name TEXT,profile TEXT);
        CREATE TABLE catalog_channel_routes(digest TEXT PRIMARY KEY,channel_id TEXT,state TEXT,reason TEXT,signature TEXT);
        CREATE TABLE public_source_routes(digest TEXT,source_id TEXT,group_name TEXT,active INTEGER);
        ''')
        group = '国际 / 美国 / 电影'
        conn.execute('INSERT INTO routes VALUES(?,?,?,?,?,?,1,0,NULL,0,4,0,0)',
                     (digest,c['name'],URL,group,'fixture',c['epgId']))
        conn.execute('INSERT INTO catalog_channels VALUES(?,?,?,?)',
                     ('action',json.dumps(c),group,json.dumps(profile(c['name'],c['epgId'],group,'US',None,True))))
        conn.execute('INSERT INTO catalog_channel_routes VALUES(?,?,?,?,?)', (digest,'action','assigned','fixture',''))
    return tmp_path, digest


def test_verified_route_market_overrides_source_country_and_unknown_routes_keep_review():
    p = profile('Action Movies', 'GB2600015OS', '国际 / 美国 / 电影', 'US', None, True, URL)
    assert p['country'] == 'GB' and p['broadcastMarketVerified'] and not p['conflict']
    assert _market_group_allowed(p, '国际 / 英国 / 电影')
    assert not _market_group_allowed(p, '国际 / 美国 / 电影')
    unknown = profile('Other', 'Other.us@UK', '国际 / 美国', 'US', None, True,
                      'https://unreviewed.example/live.m3u8')
    assert unknown['country'] == 'US' and 'broadcastMarketVerified' not in unknown


def test_apply_updates_snapshot_entity_profile_and_routes_together(catalog):
    folder, digest = catalog
    _, before = load(folder)
    batch = build_batch(folder, ['action'], authorization='explicit user review', allow_protected_shared=True)
    result = apply_batch(folder, batch)
    manifest, after = load(folder)
    assert result['state'] == 'applied' and len(result['changes']) == 1
    assert manifest['channelCount'] == 2 and manifest['routeCount'] == 2
    changed = after['channels'][0]
    assert changed['id'] == before['channels'][0]['id'] == 'action'
    assert changed['countryCode'] == 'GB' and changed['epgId'] == 'GB2600015OS'
    assert changed['routes'][0]['url'] == URL and changed['routes'][0]['revision'] == 5
    assert after['channels'][1] == before['channels'][1]
    with sqlite3.connect(folder / 'channel_inventory.sqlite3') as conn:
        metadata, group, p = conn.execute('SELECT metadata,group_name,profile FROM catalog_channels').fetchone()
        assert json.loads(metadata)['countryCode'] == json.loads(p)['country'] == 'GB'
        assert group == '国际 / 英国 / 电影'
        assert conn.execute('SELECT group_name,manual_category,revision FROM routes').fetchone() == (group,1,5)
        assert conn.execute('SELECT count(*) FROM catalog_broadcast_market_reviews').fetchone()[0] == 1
        row = conn.execute('SELECT * FROM routes').fetchone()
    assert Path(result['backupDirectory'], 'channel_inventory.sqlite3').is_file()
    assert result['epgMappingEdits'] == result['privateClientEdits'] == result['routeUrlEdits'] == 0
    queue = json.loads((folder / 'broadcast-market-review-queue.json').read_text())
    assert queue['catalogSha256'] == manifest['sha256'] and queue['automaticApplyAllowed'] is False


def test_protected_shared_entry_requires_explicit_review(catalog):
    folder, _ = catalog
    m, _ = load(folder)
    batch = build_batch(folder, ['action'], authorization='review without protected permission')
    with pytest.raises(ValueError, match='shared_protection'):
        apply_batch(folder, batch)
    assert load(folder)[0] == m


def test_unpublished_member_must_have_same_verified_market_and_stays_unpublished(catalog):
    folder, _ = catalog
    master = ('https://action-rakuten-tv-uk.fast.rakuten.tv/v1/master/'
              '0547f18649bd788bec7b67b746e47670f558b6b2/production-LiveChannel-6065/master.m3u8')
    digest = hashlib.sha256(master.encode()).hexdigest()
    with sqlite3.connect(folder / 'channel_inventory.sqlite3') as conn:
        conn.execute('INSERT INTO routes VALUES(?,?,?,?,?,?,0,0,NULL,0,0,0,0)',
                     (digest,'Action Movies',master,'国际 / 未识别地区','fixture','GB2600015OS'))
        conn.execute('INSERT INTO catalog_channel_routes VALUES(?,?,?,?,?)', (digest,'action','assigned','fixture',''))
    batch = build_batch(folder, ['action'], authorization='explicit', allow_protected_shared=True)
    assert len(batch['reviews'][0]['routeSha256']) == 1
    assert len(batch['reviews'][0]['inventoryRouteSha256']) == 2
    apply_batch(folder, batch)
    assert load(folder)[0]['routeCount'] == 2
    with sqlite3.connect(folder / 'channel_inventory.sqlite3') as conn:
        assert conn.execute('SELECT group_name,manual_category,revision FROM routes WHERE digest=?',
                            (digest,)).fetchone() == ('国际 / 英国 / 电影',0,1)


def test_concurrent_revision_change_aborts_without_publication(catalog):
    folder, _ = catalog
    m, _ = load(folder)
    batch = build_batch(folder, ['action'], authorization='explicit', allow_protected_shared=True)
    with sqlite3.connect(folder / 'channel_inventory.sqlite3') as conn:
        conn.execute('UPDATE routes SET revision=revision+1')
    with pytest.raises(ValueError, match='revision'):
        apply_batch(folder, batch)
    assert load(folder)[0] == m
    with sqlite3.connect(folder / 'channel_inventory.sqlite3') as conn:
        assert conn.execute('SELECT group_name FROM routes').fetchone()[0] == '国际 / 美国 / 电影'


def test_failed_publisher_restores_manifest_and_transaction(catalog):
    folder, _ = catalog
    m, _ = load(folder)
    old_queue = (folder / 'broadcast-market-review-queue.json').read_bytes()
    batch = build_batch(folder, ['action'], authorization='explicit', allow_protected_shared=True)
    def failed(payload, directory):
        publish(payload, directory)
        raise RuntimeError('failure after manifest replacement')
    with pytest.raises(RuntimeError):
        apply_batch(folder, batch, publisher=failed)
    assert load(folder)[0] == m
    assert (folder / 'broadcast-market-review-queue.json').read_bytes() == old_queue
    with sqlite3.connect(folder / 'channel_inventory.sqlite3') as conn:
        assert conn.execute('SELECT group_name,revision FROM routes').fetchone() == ('国际 / 美国 / 电影',4)
        assert json.loads(conn.execute('SELECT metadata FROM catalog_channels').fetchone()[0])['countryCode'] == 'US'
