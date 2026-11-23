"""Publisher facts reach publication without media URLs or playback grants."""
import json
from test_epg_auto_admit import prepared, body, META, PAGE, CHANNEL, NOW, public_fetch
import epg_evidence_review as review
import epg_publisher_admit as admission
import epg_schedule_worker as scheduler
import epg_publish_worker as publisher
import epg_store as store


def publisher_identity(conn):
    row = conn.execute('SELECT * FROM epg_research_evidence_reviews').fetchone()
    packet = json.loads(row['packet']); packet['policy'] = review.POLICY
    packet['pages'][0]['linkedRouteSha256'] = []
    facts = {'fullName': 'Fixture TV', 'operator': 'Fixture publisher', 'countryCode': 'JP',
             'feedVariant': 'Fixture TV', 'language': '', 'channelNumber': '', 'evidenceUrls': [PAGE]}
    with conn:
        conn.execute('UPDATE epg_research_evidence_reviews SET packet=?', (json.dumps(packet),))
        conn.execute('UPDATE epg_channel_research_jobs SET identity_evidence=?', (json.dumps(facts),))


def test_publisher_auto_imports_without_media_witness(prepared, tmp_path):
    publisher_identity(prepared)
    payload = body().replace(b'<url>https://fixture.example.org/live.m3u8</url>', b'')
    metadata = {k:v for k,v in META.items() if k != 'explicitProgrammeLicense'}
    result = review.validate_one_source(prepared, tmp_path, NOW, fetcher=lambda _: (payload, metadata))
    assert result['newMappings'] == result['newGrants'] == 1
    evidence = json.loads(prepared.execute('SELECT evidence FROM epg_mapping_approvals').fetchone()[0])
    assert evidence['automaticAdmission'] == admission.POLICY
    assert evidence['playbackAuthorizationGranted'] is False
    assert len(evidence['routeScope']) == 2
    assert scheduler.run(tmp_path, now=NOW)['changedChannels'] == 1
    result = publisher.run(tmp_path, now=NOW, node_fetcher=public_fetch(tmp_path, []))
    assert result['published']
    assert len(store.build_payload(prepared, NOW)['programmes']) == 2


def test_same_names_on_another_publisher_never_grant_mapping(prepared, tmp_path):
    publisher_identity(prepared)
    facts = json.loads(prepared.execute('SELECT identity_evidence FROM epg_channel_research_jobs').fetchone()[0])
    facts['evidenceUrls'] = ['https://another-publisher.example.org/channel']
    with prepared:
        prepared.execute('UPDATE epg_channel_research_jobs SET identity_evidence=?', (json.dumps(facts),))
    review.validate_one_source(prepared, tmp_path, NOW, fetcher=lambda _: (body(), {k:v for k,v in META.items() if k!='explicitProgrammeLicense'}))
    assert prepared.execute('SELECT count(*) FROM epg_mapping_approvals').fetchone()[0] == 0


def test_regional_ids_and_duplicate_services_remain_distinct():
    parsed = {'channels': {'BBCOne.uk@London': ['BBC One'], 'BBCOne.uk@Scotland': ['BBC One']}}
    facts = {'fullName': 'BBC One'}
    assert admission.choose_channel({'epgId': 'BBCOne.uk@London'}, facts, parsed) == 'BBCOne.uk@London'
    assert admission.choose_channel({'epgId': 'BBCOne.uk@NorthernIreland'}, facts, parsed) is None
    assert admission.choose_channel({'epgId': None}, facts, parsed) is None
    assert admission.guide_id('CCTV-5+@HD') != admission.guide_id('CCTV5@HD')


def test_old_route_gate_packets_are_reconsidered_without_network(prepared):
    row = prepared.execute('SELECT * FROM epg_research_evidence_reviews').fetchone()
    packet = json.loads(row['packet']); packet['policy'] = 'checked-quotes-exact-route-v1'
    packet['pages'][0]['linkedRouteSha256'] = []
    with prepared:
        prepared.execute("UPDATE epg_research_evidence_reviews SET packet=?,state='needs_route_evidence'", (json.dumps(packet),))
        prepared.execute('UPDATE epg_channel_research_jobs SET identity_evidence=NULL,next_retry=?', (NOW+3600,))
    result = review.recover_publisher_packets(prepared, NOW+1, set())
    assert result['reviewReady'] == 1
    assert prepared.execute('SELECT state FROM epg_research_evidence_reviews').fetchone()[0] == 'pending'
    assert prepared.execute('SELECT next_retry FROM epg_channel_research_jobs').fetchone()[0] == NOW+3600
