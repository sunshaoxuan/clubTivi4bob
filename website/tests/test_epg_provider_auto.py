"""Real discovery/ingestion handoffs with authored publisher API responses."""
from copy import deepcopy
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).parents[1]))
import pytest
import epg_provider_auto as auto
import epg_pluto
import epg_discovery as discovery
import epg_ingest as ingest
import epg_store as store
import epg_auto_admit
import catalog_inventory

NOW = 1795434190
ID = '1234567890abcdef12345678'
URL = 'https://service-stitcher.clusters.pluto.tv/v1/stitch/embed/hls/channel/'+ID+'/master.m3u8'
CHANNEL = {'id': 'fixture-channel', 'name': 'Fixture old name', 'countryCode': 'US',
           'regionCode': None, 'epgId': None, 'routes': [{'id': 'route-fixture', 'url': URL}]}


@pytest.fixture
def world(tmp_path, monkeypatch):
    channels = [deepcopy(CHANNEL)]
    manifest = {'version': 'fixture-v1', 'sha256': 'a'*64}
    folder = tmp_path/'channel-catalog'; folder.mkdir(); (folder/'manifest.json').write_text(json.dumps(manifest))
    monkeypatch.setattr(discovery, 'load_catalog', lambda _: (manifest, channels))
    monkeypatch.setattr(catalog_inventory, 'DATA', tmp_path)
    monkeypatch.setattr(auto, 'registry', lambda: [])
    epg_pluto._CACHE.clear()
    calls = []
    def fetch(source, now):
        calls.append(source)
        def api(url):
            stamp = lambda t: datetime.fromtimestamp(t, timezone.utc).isoformat().replace('+00:00','Z')
            return json.dumps({'_id': ID, 'slug': 'fixture-current-brand', 'name': 'Fixture current brand', 'number': 10,
                'timelines': [{'_id': str(i+1).zfill(24), 'title': 'Fixture event '+str(i),
                    'start': stamp(a), 'stop': stamp(b)} for i,(a,b) in enumerate(
                        [(NOW-100,NOW+3600), (NOW+3600,NOW+7200)])]}).encode()
        return epg_pluto.fetch_schedule(source, now, api)
    monkeypatch.setattr(auto, 'fetch_source', fetch)
    return tmp_path, channels, calls


def test_service_id_admits_publisher_feed_and_refreshes_independently(world):
    root, channels, calls = world
    result = auto.run(root, now=NOW)
    assert result['newMappings'] == 1 and result['mapped'] == [CHANNEL['id']], result['deferred']
    assert len(calls) == 1
    with ingest.database(root/'epg') as conn:
        assert conn.execute('PRAGMA journal_mode').fetchone()[0] == 'wal'
        mapping = store._approved(conn, CHANNEL['id'])
        evidence = json.loads(mapping['evidence'])
        assert evidence['automaticAdmission'] == auto.POLICY
        assert evidence['publisherServiceId'] == ID
        assert evidence['publisherNames'] == ['Fixture current brand']
        assert len(store.build_payload(conn, NOW)['programmes']) == 2
        assert len(epg_auto_admit.due_source(conn, NOW+900)) == 1
    channels[0]['routes'][0]['lastPlayableAt'] = 'a new health observation'
    assert auto.run(root, now=NOW+1)['examined'] == 0
    assert len(calls) == 1


def test_rejected_api_and_retry_survive_health_updates(world, monkeypatch):
    root, channels, calls = world
    def missing(source, now):
        calls.append(source)
        raise ingest.EpgError('http_404')
    monkeypatch.setattr(auto, 'fetch_source', missing)
    assert auto.run(root, now=NOW)['newMappings'] == 0
    channels[0]['routes'][0]['lastPlayableAt'] = 'new observation'
    assert auto.run(root, now=NOW+901)['examined'] == 0
    assert len(calls) == 1
    with ingest.database(root/'epg') as conn:
        assert conn.execute('SELECT next_retry FROM source_health').fetchone()[0] >= NOW+86400
        assert conn.execute('SELECT count(*) FROM epg_mapping_approvals').fetchone()[0] == 0


def test_manual_mappings_remain_protected(world):
    root, _, calls = world
    auto.run(root, now=NOW)
    with ingest.database(root/'epg') as conn:
        conn.execute('UPDATE epg_mapping_approvals SET locked=1')
    assert auto.run(root, now=NOW+900)['examined'] == 0
    assert len(calls) == 1


def test_delayed_or_different_service_routes_cannot_borrow_a_schedule():
    assert auto.selection(CHANNEL) == ('pluto', ID)
    c = deepcopy(CHANNEL); c['routes'][0]['url'] += '?startTime=12345'
    assert auto.selection(c) is None
    c = deepcopy(CHANNEL); c['routes'].append({'id': 'other', 'url': URL.replace(ID, 'f'*24)})
    assert auto.selection(c) is None
