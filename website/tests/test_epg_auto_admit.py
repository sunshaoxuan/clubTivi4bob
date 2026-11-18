"""Synthetic first-party proof and existing worker handoffs; no live writes."""
import hashlib
import json

import pytest
from test_epg_schedule_worker import NOW, public_fetch
import epg_auto_admit as auto
import epg_channel_research as queue
import epg_channel_research_worker as target_loader
import epg_discovery as discovery
import epg_evidence_review as review
import epg_ingest as ingest
import epg_publish_worker as publisher
import epg_schedule_worker as scheduler
import epg_store as store

ORIGIN = 'https://fixture.example.org'
URL, STREAM, PAGE = (ORIGIN + suffix for suffix in ('/guide.xml', '/live.m3u8', '/channel'))
DIGEST = hashlib.sha256(STREAM.encode()).hexdigest()
ROUTE = 'route-' + DIGEST[:24]
PATH = ['国际', '日本', '电视', '综合']
CHANNEL = {'id': 'fixture-tv', 'name': 'Fixture TV', 'countryCode': 'JP',
           'regionCode': None, 'epgId': None,
           'routes': [{'id': ROUTE, 'url': STREAM},
                      {'id': 'route-relay', 'url': 'https://relay.example.org/live.m3u8'}]}
META = {'explicitProgrammeLicense': 'CC0-1.0', 'sourceUrl': URL, 'finalUrl': URL}


def body(stream=STREAM):
    return f'''<tv><channel id="fixture"><display-name>Fixture TV</display-name>
        <url>{stream}</url></channel>
        <programme channel="fixture" start="20261016070000 +0800" stop="20261016090000 +0800"><title>Fixture current</title></programme>
        <programme channel="fixture" start="20261016090000 +0800" stop="20261016100000 +0800"><title>Fixture next</title></programme>
        </tv>'''.encode()


@pytest.fixture
def prepared(tmp_path, monkeypatch):
    target = ({'version': 'fixture'}, [CHANNEL], {CHANNEL['id']: PATH})
    monkeypatch.setattr(target_loader, 'load_targets', lambda _: target)
    monkeypatch.setattr(discovery, 'load_catalog', lambda _: target[:2])
    c = ingest.database(tmp_path)
    queue.migrate(c)
    review.migrate(c)
    store.migrate(c)
    discovery.sync_catalog(c, target[0], [CHANNEL], NOW)
    queue.enqueue(c, CHANNEL, 'fixture', PATH, NOW)
    r = c.execute('SELECT * FROM epg_channel_research_jobs').fetchone()
    packet = {'target': json.loads(r['payload']), 'pages': [{'url': PAGE, 'checkedAtUtc': NOW,
        'bodySha256': 'a'*64, 'text': 'Fixture TV technical identity', 'linkedRouteSha256': [DIGEST]}]}
    facts = {'fullName': 'Fixture TV', 'countryCode': 'JP', 'evidenceUrls': [PAGE]}
    evidence = {'technicalCheck': {'httpStatus': 200, 'contentType': 'application/xml'}}
    with c:
        c.execute('UPDATE epg_channel_research_jobs SET identity_evidence=?', (json.dumps(facts),))
        c.execute('INSERT INTO epg_research_evidence_reviews VALUES(?,?,?,?,?,?,?,NULL)',
                  (CHANNEL['id'], r['identity_hash'], 'fixture', json.dumps(packet), 'approved', 0, NOW))
        c.execute('INSERT INTO epg_research_source_candidates VALUES(?,?,?,?,?,?,?)',
                  (CHANNEL['id'], r['identity_hash'], URL, 'xmltv', 'source_registration_review_required',
                   json.dumps(evidence), NOW - 61))
    yield c
    c.close()


def test_licensed_exact_route_reaches_real_worker_publication(prepared, tmp_path):
    c = prepared
    receipt = review.validate_one_source(c, tmp_path, NOW, fetcher=lambda _: (body(), META))
    assert receipt['state'] == 'automatic_admission_approved'
    assert receipt['newGrants'] == receipt['newMappings'] == 1
    assert c.execute('SELECT count(*) FROM epg_programmes').fetchone()[0] == 0
    assert scheduler.run(tmp_path, now=NOW)['changedChannels'] == 1
    calls = []
    result = publisher.run(tmp_path, now=NOW, node_fetcher=public_fetch(tmp_path, calls))
    assert result['published'] and len(calls) == 2
    guide = store.build_payload(c, NOW)
    assert guide['channels'][0]['routeBinding']['routes'] == [{'routeId': ROUTE, 'urlSha256': DIGEST}]
    assert c.execute('SELECT count(*) FROM epg_programmes').fetchone()[0] == 2
    assert not auto.due_source(c, NOW)
    source, = auto.due_source(c, NOW + 21600)
    assert source['url'] == URL
    # A successful HTTP response without the licence must not re-enable
    # publishing cached content, including after a later transport failure.
    ingest.probe_batch(tmp_path, [source], NOW + 21600, lambda _: (body(), {}))
    with pytest.raises(ingest.EpgError, match='current_data_use_review_required'):
        store._approved(c, CHANNEL['id'])
    assert c.execute('SELECT count(*) FROM epg_programmes').fetchone()[0] == 2


@pytest.mark.parametrize('payload,metadata', [(body(), {}), (body('https://relay.example.org/live.m3u8'), META),
    (body().replace(b'20261016090000 +0800', b'20261016075900 +0800'), META)])
def test_unproven_candidate_never_enters_programme_cache(prepared, tmp_path, payload, metadata):
    c = prepared
    review.validate_one_source(c, tmp_path, NOW, fetcher=lambda _: (payload, metadata))
    for table in ('epg_data_grants', 'epg_mapping_approvals', 'epg_programmes', 'epg_source_payloads'):
        assert c.execute('SELECT count(*) FROM ' + table).fetchone()[0] == 0
