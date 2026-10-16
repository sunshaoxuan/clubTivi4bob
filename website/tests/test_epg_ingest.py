import gzip
import io
import json
from pathlib import Path
import socket
import sys

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_ingest as epg

NOW = epg.timestamp('20261016080000 +0800')
SOURCE = {'id': 'test', 'url': 'https://epg.example.org/guide.xml',
          'redirectUrls': [], 'refreshSeconds': 21600,
          'publicationAllowed': False, 'dataLicense': {'status': 'unverified'}}


def xml(programmes=None, channels='<channel id="one"><display-name>One</display-name></channel>'):
    if programmes is None:
        programmes = '''<programme channel="one" start="20261016070000 +0800" stop="20261016090000 +0800"><title>Current</title></programme>
        <programme channel="one" start="20261016090000 +0800" stop="20261016100000 +0800"><title>Next</title></programme>'''
    return f'<?xml version="1.0" encoding="UTF-8"?><tv>{channels}{programmes}</tv>'.encode()


def test_utc_provenance_and_current_future_quality():
    result = epg.parse_xmltv(gzip.compress(xml()), NOW)
    assert result['quality']['currentAndFutureChannels'] == 1
    row = result['programmes'][0]
    assert row['sourceTimezone'] == '+0800'
    assert row['sourceStart'] == '20261016070000 +0800'
    assert row['startUtc'] == NOW - 3600
    assert row['endBasis'] == 'explicit_stop'


def test_only_adjacent_start_can_infer_stop_never_last_programme():
    raw = xml('''<programme channel="one" start="20261016070000 +0800"><title>One</title></programme>
      <programme channel="one" start="20261016090000 +0800"><title>Two</title></programme>''')
    result = epg.parse_xmltv(raw, NOW)
    assert len(result['programmes']) == 1
    row = result['programmes'][0]
    assert row['endBasis'] == 'next_start'
    assert row['endUtc'] == row['derivedFromStartUtc'] == NOW + 3600
    assert result['quality']['rejected']['missing_reliable_stop'] == 1


def test_ambiguous_ids_are_quarantined_including_all_their_programmes():
    result = epg.parse_xmltv(xml(channels='''<channel id="one"><display-name>Channel V</display-name></channel>
      <channel id="one"><display-name>CDTV8</display-name></channel>'''), NOW)
    assert result['channels'] == {}
    assert result['programmes'] == []
    assert result['quality']['ambiguousChannelIds'] == ['one']


def test_identical_channel_and_programme_duplicates_are_idempotent():
    channel = '<channel id="one"><display-name>One</display-name></channel>'
    row = '<programme channel="one" start="20261016070000 +0800" stop="20261016090000 +0800"><title>Current</title></programme>'
    result = epg.parse_xmltv(xml(row * 2, channel * 2), NOW)
    assert len(result['channels']) == 1 and len(result['programmes']) == 1


def test_conflicts_overlaps_unknown_ids_and_missing_timezone_are_rejected():
    rows = '''<programme channel="one" start="20261016070000 +0800"><title>A</title></programme>
      <programme channel="one" start="20261016070000 +0800"><title>B</title></programme>
      <programme channel="one" start="20261016080000 +0800" stop="20261016100000 +0800"><title>Overlap</title></programme>
      <programme channel="one" start="20261016090000 +0800" stop="20261016100000 +0800"><title>Next</title></programme>
      <programme channel="two" start="20261016070000 +0800" stop="20261016090000 +0800"><title>Unknown</title></programme>
      <programme channel="one" start="20261016070000"><title>No zone</title></programme>'''
    result = epg.parse_xmltv(xml(rows), NOW)
    assert [p['title'] for p in result['programmes']] == ['Next']
    assert set(result['quality']['rejected']) == {'conflicting_start', 'overlapping_or_long_programme',
        'unknown_or_ambiguous_channel', 'missing_explicit_timezone'}


def test_dst_offsets_and_cross_midnight_are_exact_not_local_machine_time():
    assert epg.timestamp('20261101013000 -0400') + 3600 == epg.timestamp('20261101013000 -0500')
    assert epg.timestamp('20261016003000 +0800') == epg.timestamp('20261015163000 +0000')
    with pytest.raises(epg.EpgError):
        epg.timestamp('20261101013000 America/New_York')


@pytest.mark.parametrize('raw', [b'', b'<html/>', b'<tv>',
    b'<!DOCTYPE tv [<!ENTITY test "x">]><tv/>',
    '<!DOCTYPE tv><tv/>'.encode('utf-16'), b'<tv>\xff</tv>',
    b'<?xml version="1.0" encoding="ISO-8859-1"?><tv/>'])
def test_invalid_or_unsafe_xml_fails_closed(raw):
    with pytest.raises(epg.EpgError):
        epg.parse_xmltv(raw, NOW)


@pytest.mark.parametrize('quote', ['"', "'"])
@pytest.mark.parametrize('compressed', [False, True])
def test_fixed_standard_xmltv_doctype_is_discarded_without_dtd_resolution(monkeypatch, quote, compressed):
    def forbidden(*args, **kwargs):
        pytest.fail('XML parsing must never resolve a DTD or access the network')
    monkeypatch.setattr(socket, 'getaddrinfo', forbidden)
    monkeypatch.setattr(epg.urllib.request, 'urlopen', forbidden)
    declaration = f'<!DOCTYPE tv SYSTEM {quote}xmltv.dtd{quote}>'.encode()
    raw = xml().replace(b'<tv>', declaration + b'\n<tv>', 1)
    sanitized, removed = epg._strip_standard_xmltv_doctype(raw)
    assert removed and b'<!DOCTYPE' not in sanitized
    result = epg.parse_xmltv(gzip.compress(raw) if compressed else raw, NOW)
    baseline = epg.parse_xmltv(xml(), NOW)
    assert result['channels'] == baseline['channels'] and result['programmes'] == baseline['programmes']
    assert result['quality']['currentAndFutureChannels'] == 1
    assert result['quality']['standardXmltvDoctypeRemoved'] is True
    assert result['quality']['externalDtdResolved'] is False
    with pytest.raises(epg.EpgError, match='unsafe_xml_declaration'):
        epg.decode(raw)  # Generic/JSON decoding remains closed to every DOCTYPE.


@pytest.mark.parametrize('declaration', [
    b'<!DOCTYPE tv SYSTEM "https://example.org/xmltv.dtd">',
    b'<!DOCTYPE tv SYSTEM "file:///etc/passwd">',
    b'<!DOCTYPE tv SYSTEM "../xmltv.dtd">',
    b'<!DOCTYPE tv PUBLIC "xmltv" "xmltv.dtd">',
    b'<!DOCTYPE tv SYSTEM "xmltv.dtd" [ ]>',
    b'<!DOCTYPE tv [<!ENTITY name "Fixture">]>',
    b'<!DOCTYPE tv SYSTEM "xmltv.dtd"><!DOCTYPE tv SYSTEM "xmltv.dtd">',
    b'<!doctype tv SYSTEM "xmltv.dtd">',
    b'<!-- <!DOCTYPE tv SYSTEM "xmltv.dtd"> -->',
    b'<!DOCTYPE html>',
])
def test_doctype_compatibility_never_admits_other_declarations(declaration):
    raw = xml().replace(b'<tv>', declaration + b'<tv>', 1)
    with pytest.raises(epg.EpgError, match='unsafe_xml_declaration'):
        epg.parse_xmltv(raw, NOW)


def test_standard_doctype_cannot_appear_after_root_or_beyond_bounded_prolog():
    declaration = b'<!DOCTYPE tv SYSTEM "xmltv.dtd">'
    for raw in (xml().replace(b'<tv>', b'<tv>' + declaration, 1), b' ' * 4097 + declaration + b'<tv/>'):
        with pytest.raises(epg.EpgError, match='unsafe_xml_declaration'):
            epg.parse_xmltv(raw, NOW)


def test_gzip_truncation_trailing_member_and_bomb_are_rejected(monkeypatch):
    raw = gzip.compress(xml())
    for value in [raw[:-3], raw + gzip.compress(b'x')]:
        with pytest.raises(epg.EpgError):
            epg.decode(value)
    monkeypatch.setattr(epg, 'MAX_DECODED', 100)
    with pytest.raises(epg.EpgError):
        epg.decode(gzip.compress(b'x' * 1000))


def test_limits_are_enforced(monkeypatch):
    monkeypatch.setattr(epg, 'MAX_CHANNELS', 0)
    with pytest.raises(epg.EpgError, match='channel_limit'):
        epg.parse_xmltv(xml(), NOW)
    monkeypatch.setattr(epg, 'MAX_CHANNELS', 100)
    monkeypatch.setattr(epg, 'MAX_PROGRAMMES', 0)
    with pytest.raises(epg.EpgError, match='programme_limit'):
        epg.parse_xmltv(xml(), NOW)


class Response(io.BytesIO):
    def __init__(self, body=b'', code=200, headers=None):
        super().__init__(body)
        self.code, self.headers = code, headers or {}


class Opener:
    def __init__(self, responses):
        self.responses, self.urls = iter(responses), []
    def open(self, request, timeout):
        self.urls.append(request.full_url)
        assert timeout == 8
        return next(self.responses)


def test_redirect_not_in_exact_registry_is_never_requested():
    opener = Opener([Response(code=302, headers={'Location': 'http://127.0.0.1/private'})])
    with pytest.raises(epg.EpgError, match='unreviewed_redirect'):
        epg.fetch(SOURCE, opener)
    assert opener.urls == [SOURCE['url']]


def test_explicit_reviewed_redirect_and_payload_limit(monkeypatch):
    source = {**SOURCE, 'redirectUrls': ['https://epg.example.org/new.xml']}
    opener = Opener([Response(code=302, headers={'Location': '/new.xml'}), Response(xml())])
    payload, metadata = epg.fetch(source, opener)
    assert payload == xml() and metadata['finalUrl'].endswith('/new.xml')
    monkeypatch.setattr(epg, 'MAX_COMPRESSED', 10)
    with pytest.raises(epg.EpgError, match='compressed_size_limit'):
        epg.fetch(SOURCE, Opener([Response(b'x' * 11)]))


VERSIONED = {**SOURCE, 'url': 'https://epg.example.org/files/epg-hk.xml.gz',
             'redirectPolicy': {'kind': 'same_origin_versioned_xmltv_v1'}}
VERSION_PATH = '/files/' + 'a1' * 16 + '/epg-hk.xml.gz'


def test_reviewed_versioned_redirect_accepts_only_rotating_version_directory():
    for token in ['a1' * 16, '0' * 32]:
        path = '/files/' + token + '/epg-hk.xml.gz'
        opener = Opener([Response(code=302, headers={'Location': path}), Response(xml())])
        payload, metadata = epg.fetch(VERSIONED, opener)
        assert payload == xml() and metadata['finalUrl'] == 'https://epg.example.org' + path
        assert len(opener.urls) == 2
    assert not epg.reviewed_redirect(SOURCE, 'https://epg.example.org' + VERSION_PATH)


@pytest.mark.parametrize('target', [
    'http://epg.example.org' + VERSION_PATH,
    'https://127.0.0.1' + VERSION_PATH,
    'https://other.example.org' + VERSION_PATH,
    'https://child.epg.example.org' + VERSION_PATH,
    'https://epg.example.org:443' + VERSION_PATH,
    'https://user:password@epg.example.org' + VERSION_PATH,
    'https://epg.example.org' + VERSION_PATH + '?key=private',
    'https://epg.example.org' + VERSION_PATH + '#fragment',
    VERSION_PATH.replace('epg-hk', 'epg-tw'),
    VERSION_PATH.replace('epg-hk.xml.gz', 'unreviewed.json'),
    VERSION_PATH.replace('a1' * 16, 'A1' * 16),
    VERSION_PATH.replace('a1' * 16, 'a' * 31),
    VERSION_PATH.replace('/files/', '/other/'),
    VERSION_PATH.replace('/files/', '/files/%2e%2e/'),
    VERSION_PATH.replace('.gz', '.gz/extra'),
])
def test_versioned_redirect_escape_is_never_requested(target):
    opener = Opener([Response(code=302, headers={'Location': target})])
    with pytest.raises(epg.EpgError, match='unreviewed_redirect'):
        epg.fetch(VERSIONED, opener)
    assert opener.urls == [VERSIONED['url']]


def test_reviewed_redirect_still_has_public_dns_and_hop_limit(monkeypatch):
    visited = []
    original = epg.validate_public_url
    def checked(url):
        visited.append(url)
        original(url)
    monkeypatch.setattr(epg, 'validate_public_url', checked)
    opener = Opener([Response(code=302, headers={'Location': VERSION_PATH}) for _ in range(4)])
    with pytest.raises(epg.EpgError, match='redirect_limit'):
        epg.fetch(VERSIONED, opener)
    assert visited == opener.urls and len(visited) == 4


def test_fetch_deadline_and_upstream_retry_after():
    times = iter([0, 33])
    with pytest.raises(epg.EpgError, match='fetch_deadline'):
        epg.fetch(SOURCE, Opener([Response(xml())]), clock=lambda: next(times))
    with pytest.raises(epg.EpgError) as error:
        epg.fetch(SOURCE, Opener([Response(code=429, headers={'Retry-After': '900'})]))
    assert error.value.retry_after == 900


def test_public_dns_rebinding_protection_is_reused(monkeypatch):
    from process_channel_inventory import _public_socket
    monkeypatch.setattr(socket, 'getaddrinfo', lambda *a, **kw: [(2, 1, 6, '', ('127.0.0.1', 443))])
    with pytest.raises(ValueError, match='Non-public'):
        _public_socket('epg.example.org', 443, 8, None)


def test_persistent_success_failure_stale_false_success_and_recovery(tmp_path):
    good = lambda _: (xml(), {'finalUrl': SOURCE['url']})
    first = epg.probe_batch(tmp_path, [SOURCE], NOW, good)
    assert first['sources'][0]['state'] == 'healthy'
    assert first['published'] is False
    assert epg.probe_batch(tmp_path, [SOURCE], NOW + 1, good)['attemptedSources'] == 0
    def timeout(_):
        raise TimeoutError('sensitive upstream text must not be saved')
    failed = epg.probe_batch(tmp_path, [SOURCE], NOW + 21600, timeout)['sources'][0]
    assert failed['last_error'] == 'network_failure' and failed['failures'] == 1
    assert failed['last_success'] == NOW and failed['content_sha256'] == first['sources'][0]['content_sha256']
    stale = epg.probe_batch(tmp_path, [SOURCE], NOW + 5 * 86400, good)['sources'][0]
    assert stale['state'] == 'failed' and stale['last_success'] == NOW
    assert stale['last_good_quality'] == first['sources'][0]['last_good_quality']
    recovered = epg.probe_batch(tmp_path, [SOURCE], NOW, good)
    assert recovered['attemptedSources'] == 0  # Checkpoint cannot be bypassed by clock rollback.
    with epg.database(tmp_path) as conn:
        assert conn.execute('SELECT count(*) FROM probe_audit').fetchone()[0] == 6


def test_network_recovery_and_backoff_minimum(tmp_path):
    def limited(_):
        raise epg.EpgError('http_429', retry_after=900)
    first = epg.probe_batch(tmp_path, [SOURCE], NOW, limited)['sources'][0]
    assert first['next_retry'] >= NOW + 900
    assert epg.probe_batch(tmp_path, [SOURCE], NOW + 899, limited)['attemptedSources'] == 0
    recovered = epg.probe_batch(tmp_path, [SOURCE], first['next_retry'], lambda _: (xml(), {}))['sources'][0]
    assert recovered['state'] == 'healthy' and recovered['failures'] == 0
    assert recovered['last_failure'] == NOW


@pytest.mark.parametrize('bad_payload', [
    b'<html><head><title>Unrelated advertising page</title></head><body>Not a guide</body></html>',
    b'<!DOCTYPE html><html><title>Unrelated advertising page</title></html>',
])
def test_http_200_provider_content_drift_preserves_last_good_and_never_counts_as_success(tmp_path, bad_payload):
    first = epg.probe_batch(tmp_path, [SOURCE], NOW, lambda _: (xml(), {}))['sources'][0]
    with epg.database(tmp_path) as conn:
        identities = [tuple(row) for row in conn.execute('SELECT * FROM source_identities')]
    changed = epg.probe_batch(tmp_path, [SOURCE], NOW + SOURCE['refreshSeconds'],
        lambda _: (bad_payload, {'cacheControl': 'public, max-age=3600'}))['sources'][0]
    assert changed['state'] == 'failed'
    assert changed['last_error'] in ('not_xmltv', 'unsafe_xml_declaration')
    assert changed['last_success'] == first['last_success']
    assert changed['last_good_quality'] == first['last_good_quality']
    assert changed['content_sha256'] == first['content_sha256']
    with epg.database(tmp_path) as conn:
        assert [tuple(row) for row in conn.execute('SELECT * FROM source_identities')] == identities
        assert conn.execute('SELECT count(*) FROM probe_audit').fetchone()[0] == 4
    result = epg.probe_batch(tmp_path, [SOURCE], changed['next_retry'] - 1,
        lambda _: pytest.fail('failed source backoff must be retained'))
    assert result['attemptedSources'] == 0 and result['published'] is False


def test_interrupted_worker_has_durable_checkpoint_and_resumes(tmp_path):
    def interrupted(_):
        raise KeyboardInterrupt()
    with pytest.raises(KeyboardInterrupt):
        epg.probe_batch(tmp_path, [SOURCE], NOW, interrupted)
    with epg.database(tmp_path) as conn:
        row = dict(conn.execute('SELECT * FROM source_health').fetchone())
        assert row['state'] == 'probing' and row['failures'] == 1
        assert row['next_retry'] >= NOW + 120
    assert epg.probe_batch(tmp_path, [SOURCE], NOW + 119, interrupted)['attemptedSources'] == 0
    recovered = epg.probe_batch(tmp_path, [SOURCE], row['next_retry'], lambda _: (xml(), {}))['sources'][0]
    assert recovered['state'] == 'healthy'
    assert recovered['last_failure'] == NOW
    with epg.database(tmp_path) as conn:
        assert conn.execute("SELECT count(*) FROM probe_audit WHERE error_code='worker_interrupted'").fetchone()[0] == 1


def test_batch_bound_and_changed_identity_preserve_history(tmp_path):
    sources = [SOURCE, {**SOURCE, 'id': 'second'}]
    assert epg.probe_batch(tmp_path, sources, NOW, lambda _: (xml(), {}))['attemptedSources'] == 1
    assert epg.probe_batch(tmp_path, sources, NOW, lambda _: (xml(), {}))['attemptedSources'] == 1
    with pytest.raises(epg.EpgError, match='configuration_changed'):
        epg.probe_batch(tmp_path, [{**SOURCE, 'url': 'https://other.example.org/new.xml'}], NOW)
    with pytest.raises(epg.EpgError, match='batch_size_limit'):
        epg.probe_batch(tmp_path, sources, NOW, batch_size=6)


def test_registry_rejects_missing_rights_and_unimplemented_publication(tmp_path):
    path = tmp_path / 'sources.json'
    path.write_text(json.dumps({'schemaVersion': 1, 'sources': [SOURCE]}))
    assert epg.registry(path) == [SOURCE]
    path.write_text(json.dumps({'schemaVersion': 1, 'sources': [{**SOURCE, 'publicationAllowed': True}]}))
    with pytest.raises(epg.EpgError, match='publishing_not_implemented'):
        epg.registry(path)


def test_checked_in_registry_never_authorizes_publication():
    assert all(source['publicationAllowed'] is False for source in epg.registry())


@pytest.mark.parametrize('policy', [None, {}, {'kind': 'arbitrary-regex'},
    {'kind': 'same_origin_versioned_xmltv_v1', 'host': 'unreviewed.example.org'}])
def test_registry_rejects_unreviewed_redirect_policy(tmp_path, policy):
    path = tmp_path / 'sources.json'
    path.write_text(json.dumps({'schemaVersion': 1, 'sources': [{**VERSIONED, 'redirectPolicy': policy}]}))
    with pytest.raises(epg.EpgError, match='invalid_redirect_policy'):
        epg.registry(path)


def test_configuration_revision_preserves_old_health_identity_and_attempts(tmp_path):
    epg.probe_batch(tmp_path, [SOURCE], NOW, lambda _: (xml(), {}))
    with epg.database(tmp_path) as conn:
        old = dict(conn.execute('SELECT * FROM source_health').fetchone())
        identities = [tuple(row) for row in conn.execute('SELECT * FROM source_identities')]
    revised = {**SOURCE, 'id': 'test-reviewed-v1',
        'supersedes': {'sourceId': 'test', 'reason': 'Explicitly reviewed redirect policy revision'}}
    fetched = []
    def failed(source):
        fetched.append(source['id'])
        raise TimeoutError()
    epg.probe_batch(tmp_path, [revised], NOW + 1, failed)
    epg.probe_batch(tmp_path, [revised], NOW + 2, failed)
    assert fetched == ['test-reviewed-v1']
    with epg.database(tmp_path) as conn:
        retained = dict(conn.execute("SELECT * FROM source_health WHERE id='test'").fetchone())
        assert retained == {**old, 'state': 'superseded'}
        assert [tuple(row) for row in conn.execute("SELECT * FROM source_identities WHERE source_id='test'")] == identities
        assert conn.execute('SELECT count(*) FROM source_replacements').fetchone()[0] == 1
        assert conn.execute("SELECT count(*) FROM probe_audit WHERE source_id='test'").fetchone()[0] == 3
        import epg_discovery
        _, ids, names = epg_discovery.source_index(conn, NOW + 2)
        assert not ids and not names
    with pytest.raises(epg.EpgError, match='invalid_source_replacement'):
        epg.probe_batch(tmp_path, [{**SOURCE, 'id': 'unrelated', 'url': 'https://other.example.org/guide.xml',
            'supersedes': revised['supersedes']}], NOW + 3, failed)


def test_replacement_must_be_known_and_removed_from_active_registry(tmp_path):
    revised = {**SOURCE, 'id': 'replacement', 'supersedes': {'sourceId': SOURCE['id'], 'reason': 'Reviewed'}}
    with pytest.raises(epg.EpgError, match='invalid_source_replacement'):
        epg.probe_batch(tmp_path, [revised], NOW, lambda _: (xml(), {}))
    with epg.database(tmp_path) as conn:
        assert conn.execute('SELECT count(*) FROM source_health').fetchone()[0] == 0
    path = tmp_path / 'sources.json'
    path.write_text(json.dumps({'schemaVersion': 1, 'sources': [SOURCE, revised]}))
    with pytest.raises(epg.EpgError, match='replacement_source_still_active'):
        epg.registry(path)
