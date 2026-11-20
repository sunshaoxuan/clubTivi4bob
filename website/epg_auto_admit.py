"""Conservative first-party XMLTV admission. No model or search hit grants rights."""
import json
import hashlib
import re
from urllib.parse import urlsplit

from epg_ingest import EpgError

POLICY = 'first_party_xmltv_cc0_v1'


def proof(metadata, source):
    return (isinstance(metadata, dict) and metadata.get('explicitProgrammeLicense') == 'CC0-1.0'
            and metadata.get('sourceUrl') == source['url'] == metadata.get('finalUrl')
            and urlsplit(source['url']).scheme == 'https')


def mappings(conn, source):
    exists = conn.execute("SELECT 1 FROM sqlite_master WHERE name='epg_mapping_approvals'").fetchone()
    if not exists:
        return []
    return [(row['channel_id'], row['original_id'], e) for row in conn.execute(
        'SELECT * FROM epg_mapping_approvals WHERE source_id=? AND revoked=0', (source['id'],))
        if (e := json.loads(row['evidence'])).get('automaticAdmission') == POLICY]


def check_refresh(conn, source, metadata, parsed):
    for _, original, evidence in mappings(conn, source):
        scope = evidence['routeScope']
        expected = (urlsplit(source['url']).netloc.lower(), scope[0]['urlSha256']) if len(scope) == 1 else None
        if (not proof(metadata, source) or len(scope) != 1
                or parsed['routeProofs'].get(original) != expected
                or sum(value == expected for value in parsed['routeProofs'].values()) != 1
                or evidence['officialFullName'] not in parsed['channels'].get(original, [])):
            raise EpgError('automatic_source_proof_changed')


def admit(conn, target, source, metadata, parsed, now, *, catalogue=None):
    """Use current checked identity pages and a feed-scoped CC0 licence link.

    In v1 the identity witness, the guide and the exact stream must all be on
    the same HTTPS origin. This intentionally excludes opaque CDN relays.
    """
    from epg_evidence_review import _fresh_page
    from catalog_inventory import DATA
    from epg_channel_research_worker import load_targets
    from epg_auto_search_worker import target_hash
    import epg_store as store
    cid, identity_hash = target
    if not proof(metadata, source):
        return False
    row = conn.execute('''SELECT j.*,e.packet,e.state AS proof_state
        FROM epg_channel_research_jobs j JOIN epg_research_evidence_reviews e
        USING(channel_id,identity_hash)
        WHERE j.channel_id=? AND j.identity_hash=? AND j.active=1
          AND j.identity_evidence IS NOT NULL AND j.lease_until<=?''',
        (cid, identity_hash, now)).fetchone()
    if not row or row['proof_state'] != 'approved':
        return False
    facts, packet, saved = (json.loads(row[k]) for k in ('identity_evidence', 'packet', 'payload'))
    if packet.get('target') != saved or packet.get('unresolvedDirectoryCountryConflict'):
        return False
    _, channels, paths = catalogue if catalogue is not None else load_targets(DATA)
    channel = next((c for c in channels if c['id'] == cid), None)
    if not channel or target_hash(channel, paths[cid]) != identity_hash:
        return False
    origin = urlsplit(source['url']).netloc.lower()
    routes = set(saved['routeSha256'])
    witnesses = {}
    for page in packet.get('pages', []):
        page = _fresh_page(page, routes, now)
        if page and page['url'] in facts['evidenceUrls']:
            url = urlsplit(page['url'])
            if url.scheme == 'https' and url.netloc.lower() == origin:
                for digest in page['linkedRouteSha256']:
                    witnesses[digest] = page['url']
    matches = [(original, route[1]) for original, route in parsed['routeProofs'].items()
               if route and route[0] == origin and route[1] in witnesses
               and facts['fullName'] in parsed['channels'].get(original, [])]
    if len(matches) != 1:
        return False
    original, digest = matches[0]
    if sum(route == (origin, digest) for route in parsed['routeProofs'].values()) != 1:
        return False
    selected = [r for r in channel['routes'] if hashlib.sha256(r['url'].encode()).hexdigest() == digest]
    if len(selected) != 1 or not re.fullmatch(r'route-[a-f0-9]{24}', selected[0].get('id', '')):
        return False
    rows = [p for p in parsed['programmes'] if p['originalChannelId'] == original]
    if (sum(p['startUtc'] <= now < p['endUtc'] for p in rows) != 1
            or not any(p['startUtc'] > now for p in rows)):
        return False
    evidence = {'automaticAdmission': POLICY, 'officialFullName': facts['fullName'],
        'evidenceUrl': witnesses[digest], 'countryCode': channel['countryCode'],
        'regionCode': channel.get('regionCode'), 'sourceCountryCode': facts['countryCode'],
        'sourceRegionCode': channel.get('regionCode'), 'sameChannelAndDelayVersion': True,
        'routeScopeExplicitlyReviewed': True,
        'routeScope': [{'routeId': selected[0]['id'], 'urlSha256': digest}]}
    # Grant and mapping are one transaction. Never replace any pre-existing
    # approval, including a revoked approval or a curator's source grant.
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        if (conn.execute('SELECT 1 FROM epg_mapping_approvals WHERE channel_id=?', (cid,)).fetchone()
                or conn.execute('SELECT 1 FROM epg_data_grants WHERE source_id=?', (source['id'],)).fetchone()):
            return False
        current = conn.execute('SELECT identity_evidence,identity_hash,active,lease_until FROM epg_channel_research_jobs WHERE channel_id=?', (cid,)).fetchone()
        if tuple(current or ()) != (row['identity_evidence'], identity_hash, 1, row['lease_until']):
            return False
        store.approve_data_use(conn, source['id'], source_url=source['url'], evidence_url=source['url'],
            data_license='CC0 1.0', programme_data_permission=True, now=now, in_transaction=True)
        store.approve_mapping(conn, cid, source['id'], original, evidence=evidence, now=now, in_transaction=True)
        conn.execute('INSERT INTO probe_audit(source_id,checked_at,state) VALUES(?,?,?)',
                     (source['id'], now, 'automatic_admission_approved'))
    return True


def due_source(conn, now):
    # At most one discovered source; registry sources keep their normal worker
    # and budget. Failed and interrupted sources retain their existing retry.
    if not conn.execute("SELECT 1 FROM sqlite_master WHERE name='epg_mapping_approvals'").fetchone():
        return []
    row = conn.execute('''SELECT h.configuration FROM source_health h
      JOIN epg_mapping_approvals a ON a.source_id=h.id AND a.revoked=0
      JOIN epg_data_grants g ON g.source_id=h.id AND g.revoked=0
      WHERE h.id LIKE 'channel-xmltv-%' AND h.next_retry<=?
      AND h.state NOT IN ('manual_review','superseded')
      AND json_extract(a.evidence,'$.automaticAdmission')=?
      ORDER BY h.next_retry,h.id LIMIT 1''', (now, POLICY)).fetchone()
    return [json.loads(row[0])] if row else []
