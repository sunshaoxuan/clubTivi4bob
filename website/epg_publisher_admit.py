"""Automatic factual XMLTV admission after checked publisher/channel review.

No delivery URL needs to occur on publisher pages. Existing playback routes are
only scoped client bindings; EPG discovery grants no playback permission.
"""
import hashlib
import json
import re
from urllib.parse import urlsplit

from epg_discovery import canonical

POLICY = 'publisher_xmltv_facts_v2'


def guide_id(value):
    return canonical(re.sub(r'@(sd|hd|fhd|uhd|\d{3,4}p)$', '', canonical(value), flags=re.I))


def publisher_host(url):
    from epg_auto_search import DIRECTORIES
    p = urlsplit(url)
    host = p.hostname or ''
    if (p.scheme != 'https' or not host or p.username or p.password
            or any(host == d or host.endswith('.'+d) for d in
                   [*DIRECTORIES, 'github.com', 'github.io', 'epg.pw', 'cloudfront.net', 'google.com'])):
        return None
    return host.removeprefix('www.')


def choose_channel(channel, facts, parsed):
    name = canonical(facts['fullName'])
    matches = [oid for oid, names in parsed['channels'].items() if name in {canonical(n) for n in names}]
    epg_id = channel.get('epgId')
    if epg_id:
        matches = [oid for oid in matches if guide_id(oid) == guide_id(epg_id)]
    return matches[0] if len(matches) == 1 else None


def admit(conn, target, source, metadata, parsed, now, *, catalogue=None):
    from epg_evidence_review import _fresh_page, POLICY as REVIEW_POLICY
    from epg_channel_research_worker import load_targets
    from epg_auto_search_worker import target_hash
    from catalog_inventory import DATA
    import epg_store as store
    cid, identity_hash = target
    row = conn.execute('''SELECT j.*,r.packet,r.state AS review_state
      FROM epg_channel_research_jobs j JOIN epg_research_evidence_reviews r USING(channel_id,identity_hash)
      WHERE j.channel_id=? AND j.identity_hash=? AND j.active=1 AND j.identity_evidence IS NOT NULL
      AND j.lease_until<=?''', (cid, identity_hash, now)).fetchone()
    if not row or row['review_state'] != 'approved':
        return False
    facts, packet, saved = (json.loads(row[k]) for k in ('identity_evidence', 'packet', 'payload'))
    if packet.get('policy') != REVIEW_POLICY or packet.get('target') != saved or packet.get('unresolvedDirectoryCountryConflict'):
        return False
    store.migrate(conn)
    grant = conn.execute('SELECT revoked FROM epg_data_grants WHERE source_id=?', (source['id'],)).fetchone()
    if grant and (grant['revoked'] or store.reviewed_data_use(conn, source['id']) is None):
        return False
    operator_url = facts['evidenceUrls'][0]
    host = publisher_host(operator_url)
    guide_host = urlsplit(source['url']).hostname or ''
    publisher_linked = any(hashlib.sha256(source['url'].encode()).hexdigest() in p.get('programmeReferenceSha256', [])
        for p in packet['pages'] if p['url'] == operator_url and _fresh_page(p, set(saved['routeSha256']), now))
    if (not host or not (guide_host == host or guide_host.endswith('.'+host) or publisher_linked)
            or urlsplit(source['url']).scheme != 'https'
            or not isinstance(metadata, dict) or metadata.get('sourceUrl') != source['url']
            or metadata.get('finalUrl') != source['url']):
        return False
    pages = [p for p in packet['pages'] if p['url'] == operator_url
             and _fresh_page(p, set(saved['routeSha256']), now)]
    if len(pages) != 1:
        return False
    _, channels, paths = catalogue if catalogue is not None else load_targets(DATA)
    channel = next((c for c in channels if c['id'] == cid), None)
    if not channel or target_hash(channel, paths[cid]) != identity_hash:
        return False
    if source.get('format') == 'publisher-json':
        original = next(iter(parsed['channels']), None) if (
            source.get('catalogChannelId') == cid and len(parsed['channels']) == 1
            and canonical(source.get('channelName')) == canonical(facts['fullName'])) else None
    else:
        original = choose_channel(channel, facts, parsed)
    if original is None:
        return False
    events = [p for p in parsed['programmes'] if p['originalChannelId'] == original]
    if (sum(p['startUtc'] <= now < p['endUtc'] for p in events) != 1
            or not any(p['startUtc'] > now for p in events)):
        return False
    previous = conn.execute('SELECT * FROM epg_mapping_approvals WHERE channel_id=?', (cid,)).fetchone()
    # A fresh publisher review may repair this worker's own unpinned mapping.
    # Curated, manually pinned and explicitly revoked mappings stay protected.
    if previous and (previous['revoked'] or previous['locked']
            or json.loads(previous['evidence']).get('automaticAdmission') != POLICY):
        return False
    scope = sorted([{'routeId': r['id'], 'urlSha256': hashlib.sha256(r['url'].encode()).hexdigest()}
                    for r in channel['routes']], key=lambda r: r['routeId'])
    if not scope:
        return False
    evidence = {'automaticAdmission': POLICY, 'evidenceUrl': operator_url,
        'countryCode': channel['countryCode'], 'regionCode': channel.get('regionCode'),
        'sourceCountryCode': facts['countryCode'], 'sourceRegionCode': channel.get('regionCode'),
        'sameChannelAndDelayVersion': True, 'publisher': facts['operator'],
        'officialFullName': facts['fullName'], 'feedVariant': facts['feedVariant'],
        'routeScopeExplicitlyReviewed': True, 'routeScope': scope,
        'dataScope': 'factual title, explicit start/stop and channel identifiers only',
        'playbackAuthorizationGranted': False}
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        latest = conn.execute('SELECT * FROM epg_mapping_approvals WHERE channel_id=?', (cid,)).fetchone()
        if (dict(latest) if latest else None) != (dict(previous) if previous else None):
            return False
        current = conn.execute('SELECT identity_hash,identity_evidence,active FROM epg_channel_research_jobs WHERE channel_id=?', (cid,)).fetchone()
        if tuple(current or ()) != (identity_hash, row['identity_evidence'], 1):
            return False
        if store.reviewed_data_use(conn, source['id']) is None:
            store.approve_data_use(conn, source['id'], source_url=source['url'], evidence_url=operator_url,
                data_license='Operator-authorized publisher schedule facts; title and start/stop only',
                programme_data_permission=True, now=now, in_transaction=True)
        store.approve_mapping(conn, cid, source['id'], original, evidence=evidence,
                              locked=False, now=now, in_transaction=True)
        conn.execute('INSERT INTO probe_audit(source_id,checked_at,state) VALUES(?,?,?)',
                     (source['id'], now, 'publisher_facts_admission_approved'))
    return True
