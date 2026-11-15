import copy
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))
from broadcast_market import provider_service, resolve_market, review_channel
from audit_broadcast_markets import edition_hints, audit
from country_names import _DATA

HOST = 'action-rakuten-tv-uk.fast.rakuten.tv'
ROOT = 'https://' + HOST + '/v1/manifest/' + 'a' * 40 + '/production-LiveChannel-6065/'
URL = ROOT + '12345678-1234-1234-1234-123456789abc/4.m3u8'
BINDING = dict(provider='rakuten-tv', host=HOST, serviceId='6065', market='GB',
               evidenceUrls=['https://gizmo.rakuten.tv/v3/live_channels/action-rakuten-tv'])


def channel(urls=(URL,)):
    return dict(id='action', name='Action Movies', epgId='GB2600015OS', countryCode='US',
                regionCode=None, categoryId='movie', routes=[{'url': u} for u in urls])


def test_exact_service_binding_wins_over_irrelevant_origin_and_language():
    c = channel()
    c.update(operatorCountry='ES', contentCountry='US', language='ENG')
    assert resolve_market(c, [BINDING])['market'] == 'GB'
    assert resolve_market(c, [])['market'] is None


def test_unreviewed_route_or_mixed_editions_require_review():
    assert resolve_market(channel([URL, 'https://proxy.example/movie.m3u8']), [BINDING])['reason'] == 'unbound_route'
    de_url = URL.replace('-uk.fast', '-de.fast').replace('6065', '6066')
    de = {**BINDING, 'host': HOST.replace('-uk.fast', '-de.fast'), 'serviceId': '6066', 'market': 'DE'}
    assert resolve_market(channel([URL, de_url]), [BINDING, de])['reason'] == 'mixed_feed_markets'


def test_no_inference_from_epg_suffix_country_name_or_counterfeit_host():
    for url in [URL.replace(HOST, HOST + '.example.com'),
                URL.replace('https://', 'http://'), URL.replace('6065', '6066'),
                URL.replace(HOST, 'uk.movie.example.org'), URL + '#6065']:
        assert resolve_market(channel([url]), [BINDING])['market'] is None
    c = channel(['https://proxy.example/GB2600015OS.m3u8'])
    c.update(name='Action Movies UK', epgId='ActionMovies.gb')
    assert resolve_market(c, [BINDING])['market'] is None


def test_sessions_and_signed_queries_do_not_select_market():
    master = 'https://' + HOST + '/v1/master/' + 'a' * 40 + '/production-LiveChannel-6065/master.m3u8'
    assert provider_service(URL) == provider_service(master + '?market=us')


def test_conflicting_reviewed_facts_abstain():
    assert resolve_market(channel(), [BINDING, {**BINDING, 'market': 'US'}])['reason'] == 'conflicting_binding'


def test_epg_quality_suffix_is_not_sudan_and_edition_is_only_a_review_hint():
    c = channel(['https://proxy.example/live.m3u8'])
    c['epgId'] = 'CCTV1.cn@SD'
    assert edition_hints(c, _DATA['names']) == []
    c['epgId'] = 'RakutenTVActionMovies.es@Germany'
    assert edition_hints(c, _DATA['names']) == [
        {'kind': 'explicit_epg_edition_suffix', 'marketHint': 'DE'}]
    assert resolve_market(c, [BINDING])['market'] is None
    c['epgId'] = 'Fixture.us@UK'
    assert edition_hints(c, _DATA['names'])[0]['marketHint'] == 'GB'


def test_proposal_updates_geography_and_path_together_without_mutation_or_epg_edits():
    c = channel()
    categories = {'world': dict(name='国际', parentId=None), 'us': dict(name='美国', parentId='world'),
                  'movie': dict(name='电影', parentId='us')}
    before = copy.deepcopy(c)
    r = review_channel(c, categories, [BINDING], {'gb': '英国'})
    assert r['status'] == 'proposed_correction'
    assert r['proposedCountryCode'] == 'GB'
    assert r['proposedPath'] == ['国际', '英国', '电影']
    assert r['expectedIdentity']['epgId'] == 'GB2600015OS'
    assert c == before
    assert review_channel(c, categories, [BINDING], {'gb': '英国'}, protected=True)['status'] == 'protected_review'


def test_full_audit_separates_country_conflicts_from_label_scope_and_keeps_manual_protection():
    categories = [dict(id='w', name='国际', parentId=None),
                  dict(id='us', name='美国', parentId='w'),
                  dict(id='ug', name='乌干达', parentId='w'),
                  dict(id='bq', name='博奈尔', parentId='w'),
                  dict(id='movie', name='电影', parentId='us')]
    channels = [channel(), dict(channel(), id='btv', categoryId='ug', countryCode='CN',
                                epgId='BTV.ug@SD', routes=[{'url': 'https://a.example/b.m3u8'}]),
                dict(channel(), id='bonaire', categoryId='bq', countryCode='BQ',
                     epgId='NosTV.bq@SD', routes=[{'url': 'https://a.example/c.m3u8'}])]
    payload = dict(version='fixture', categories=categories, channels=channels)
    before = copy.deepcopy(payload)
    result = audit(payload, [BINDING], {'action'})
    assert result['summary'] == {'protected_review': 1, 'unbound': 2}
    assert result['findingKinds']['category_metadata_country_conflict'] == 1
    assert result['findingKinds']['category_label_scope_difference'] == 1
    assert result['appliedChanges'] == result['newEpgMappings'] == 0
    assert payload == before


def test_uk_and_gb_are_one_market_and_sd_is_not_a_geography_finding():
    payload = dict(version='fixture', categories=[dict(id='world', name='国际', parentId=None),
                   dict(id='movie', name='英国', parentId='world')],
                   channels=[dict(channel(['https://a.example/b.m3u8']), countryCode='GB', epgId='Fixture.us@UK')])
    assert audit(payload, [])['reviewFindingCount'] == 0


def test_delivery_hostname_needs_explicit_reviewed_service_binding():
    alias='https://'+'b'*32+'.mediatailor.eu-west-1.amazonaws.com/v1/master/'+'a'*40+'/production-LiveChannel-6065/master.m3u8'
    assert resolve_market(channel([URL,alias]),[BINDING])['market'] is None
    reviewed={**BINDING,'host':'b'*32+'.mediatailor.eu-west-1.amazonaws.com'}
    assert resolve_market(channel([URL,alias]),[BINDING,reviewed])['market']=='GB'
    assert resolve_market(channel([URL,alias.replace('6065','6066')]),[BINDING,reviewed])['market'] is None


def test_pluto_global_id_requires_reviewed_country_binding_and_ignores_query_market():
    identity='5d4947590ba40f75dc29c26b'
    route='https://service-stitcher.clusters.pluto.tv/stitch/hls/channel/'+identity+'/master.m3u8?marketingRegion=US'
    binding=dict(provider='pluto-tv',host='service-stitcher.clusters.pluto.tv',serviceId=identity,market='DE',
                 evidenceUrls=['https://api.pluto.tv/v2/channels/'+identity])
    assert provider_service(route)==('pluto-tv','service-stitcher.clusters.pluto.tv',identity)
    assert resolve_market(channel([route]),[])['market'] is None
    assert resolve_market(channel([route]),[binding])['market']=='DE'
    assert resolve_market(channel([route,route.replace(identity,'f'*24)]),[binding])['market'] is None
    assert provider_service(route.replace('pluto.tv','pluto.tv.attacker.example')) is None
