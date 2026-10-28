"""Resume five-channel batches of internal EPG identity candidate review.

No fuzzy/substring/category-only matching, no AI calls, no private favourites,
no public EPG publication and no automatic player mapping writes in this stage.
"""
import argparse
from collections import defaultdict
import fcntl
import gzip
import hashlib
import json
from pathlib import Path
import re
import time
import unicodedata

from catalog_inventory import DATA
from epg_ingest import EpgError, database, registry, seed_cached_identities

REVIEW_POLICY = 'licensed_structured_country_identifier_v1'


def network_name_token(value):
    """Full-name typography only; never drop plus signs, numbers or words."""
    value = canonical(value)
    if not re.fullmatch(r'[a-z0-9]+(?:[ ._-]+[a-z0-9]+)*', value):
        return None
    return re.sub(r'[ ._-]', '', value)


def structured_identifier(channel):
    match = re.fullmatch(r'([A-Za-z0-9]+)\.([a-z]{2})(?:@([A-Za-z0-9+_-]+))?',
        channel.get('epgId') or '')
    if not match:
        return None
    country = {'uk': 'GB'}.get(match[2], match[2].upper())
    if country != channel.get('countryCode'):
        return None
    variant = match[3]
    # National US networks cannot establish affiliate station schedules.
    if country == 'US' and variant:
        return None
    if variant and ('+' in variant or re.search(r'plus\d|delay|timeshift', variant, re.I)):
        return None
    return {'field': 'epgId', 'value': match[0], 'countryCode': country,
        'networkToken': match[1].casefold(), 'retainedVariant': variant,
        'feedVariantVerified': False}


def canonical(value):
    value = re.sub(r'\s+', ' ', unicodedata.normalize('NFKC', value or '').strip()).casefold()
    cctv = re.fullmatch(r'cctv[- ]?(\d{1,2})(\+)?', value)
    if cctv:
        return 'cctv' + str(int(cctv[1])) + (cctv[2] or '')
    return value


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
        separators=(',', ':')).encode()).hexdigest()


def migrate(conn):
    conn.executescript('''
      CREATE TABLE IF NOT EXISTS discovery_jobs (
        channel_id TEXT PRIMARY KEY, identity_hash TEXT NOT NULL, payload TEXT NOT NULL,
        catalog_version TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1,
        priority INTEGER NOT NULL, state TEXT NOT NULL DEFAULT 'pending',
        source_generation TEXT NOT NULL DEFAULT '', next_retry INTEGER NOT NULL DEFAULT 0,
        lease_until INTEGER NOT NULL DEFAULT 0, lease_token TEXT, updated_at INTEGER NOT NULL,
        candidates TEXT NOT NULL DEFAULT '[]', reason TEXT);
      CREATE INDEX IF NOT EXISTS discovery_due ON discovery_jobs(active,state,next_retry,priority);
      CREATE TABLE IF NOT EXISTS mapping_review_audit (
        id INTEGER PRIMARY KEY, channel_id TEXT NOT NULL, identity_hash TEXT NOT NULL,
        source_generation TEXT NOT NULL, checked_at INTEGER NOT NULL,
        state TEXT NOT NULL, reason TEXT NOT NULL, candidates TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS epg_checkpoints (name TEXT PRIMARY KEY, value TEXT NOT NULL);
    ''')


def load_catalog(data_dir):
    base = Path(data_dir) / 'channel-catalog'
    manifest = json.loads((base / 'manifest.json').read_text())
    digest = manifest.get('sha256', '')
    if not re.fullmatch(r'[a-f0-9]{64}', digest):
        raise EpgError('invalid_catalog_digest')
    path = base / 'snapshots' / (digest + '.json.gz')
    if path.stat().st_size > 32 * 1024 * 1024:
        raise EpgError('catalog_compressed_limit')
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != digest:
        raise EpgError('catalog_checksum_mismatch')
    # The trusted local catalogue publisher caps input at 10,000 channels.
    import zlib
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    payload = decoder.decompress(raw, 64 * 1024 * 1024 + 1)
    if len(payload) > 64 * 1024 * 1024 or not decoder.eof or decoder.unused_data:
        raise EpgError('catalog_decoded_limit')
    catalog = json.loads(payload)
    channels = catalog.get('channels')
    if catalog.get('version') != manifest.get('version') or not isinstance(channels, list) or not 1 <= len(channels) <= 10000 or len(channels) != manifest.get('channelCount'):
        raise EpgError('invalid_catalog_snapshot')
    if len({c['id'] for c in channels}) != len(channels):
        raise EpgError('duplicate_catalog_identity')
    return manifest, channels


def priority(channel):
    # No private favourites are sent to this queue. Playback is already-public
    # route evidence; jurisdiction is the explicit catalog country, not a guess.
    country = channel.get('countryCode')
    playable = any(r.get('lastPlayableAt') for r in channel.get('routes', []))
    return (0 if country in ('CN', 'HK', 'MO', 'TW') else 10) + (0 if playable else 1)


def sync_catalog(conn, manifest, channels, now):
    migrate(conn)
    # Fingerprinting and serialization scale with the public catalogue. Keep
    # that CPU work outside the write transaction and avoid unchanged writes.
    prepared = []
    for channel in channels:
        identity = {key: channel.get(key) for key in ('id', 'name', 'epgId', 'countryCode', 'regionCode')}
        prepared.append((channel['id'], fingerprint(identity),
            json.dumps(identity, ensure_ascii=False), priority(channel)))
    current_ids = {item[0] for item in prepared}
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        existing = {row['channel_id']: row for row in conn.execute(
            'SELECT channel_id,identity_hash,active,catalog_version,priority FROM discovery_jobs')}
        removed = [(key,) for key, row in existing.items() if row['active'] and key not in current_ids]
        conn.executemany('UPDATE discovery_jobs SET active=0 WHERE channel_id=?', removed)
        unchanged_identity_updates = []
        for channel_id, digest, payload, item_priority in prepared:
            old = existing.get(channel_id)
            if old is None:
                conn.execute('INSERT INTO discovery_jobs(channel_id,identity_hash,payload,catalog_version,priority,updated_at) VALUES(?,?,?,?,?,?)',
                    (channel_id, digest, payload, manifest['version'], item_priority, now))
            elif old['identity_hash'] != digest:
                conn.execute('''UPDATE discovery_jobs SET identity_hash=?,payload=?,catalog_version=?,active=1,priority=?,
                    state='pending',source_generation='',next_retry=0,lease_until=0,lease_token=NULL,candidates='[]',reason=NULL,updated_at=? WHERE channel_id=?''',
                    (digest, payload, manifest['version'], item_priority, now, channel_id))
            elif (not old['active'] or old['catalog_version'] != manifest['version']
                    or old['priority'] != item_priority):
                unchanged_identity_updates.append((manifest['version'], item_priority, channel_id))
        conn.executemany('UPDATE discovery_jobs SET active=1,catalog_version=?,priority=? WHERE channel_id=?',
            unchanged_identity_updates)
        conn.execute('''INSERT INTO epg_checkpoints VALUES(?,?) ON CONFLICT(name)
            DO UPDATE SET value=excluded.value WHERE value!=excluded.value''', ('catalog', json.dumps(manifest)))


def source_index(conn, now):
    # Lazy import avoids a module cycle. This is read-only grant metadata;
    # source data permission never establishes the identity of a catalog feed.
    from epg_store import reviewed_data_use
    rows = conn.execute('''SELECT i.*,h.configuration,h.failures,h.last_success,c.context_json FROM source_identities i
      JOIN source_health h ON h.id=i.source_id
      LEFT JOIN source_identity_context c ON c.source_id=i.source_id AND c.original_id=i.original_id
      WHERE h.last_success IS NOT NULL AND h.failures<3 AND h.state!='superseded'
      ORDER BY i.source_id,i.original_id''').fetchall()
    ids, names = defaultdict(list), defaultdict(list)
    generation = []
    rights = {}
    for row in rows:
        config = json.loads(row['configuration'])
        if now - row['fetched_at'] > config['refreshSeconds'] * 2:
            continue
        entry = dict(row)
        entry['names'] = json.loads(entry.pop('names_json'))
        entry['context'] = json.loads(entry.pop('context_json') or '{}')
        if entry['source_id'] not in rights:
            rights[entry['source_id']] = reviewed_data_use(conn, entry['source_id'])
        entry['dataRightsReview'] = rights[entry['source_id']]
        # Identity evidence remains metadata after a programme window ends.
        # Eligibility still expires at twice the configured fetch interval and
        # persistent source failures or supersession still remove candidates.
        # Only the separate programme store/coverage guards may establish live
        # programme availability; a candidate never counts as that coverage.
        # Changes in programmes alone do not cause repeated identity review.
        generation.append([entry['source_id'], entry['original_id'], entry['names']]
            + ([entry['context']] if entry['context'] else [])
            + ([{'dataRightsReview': entry['dataRightsReview']}] if entry['dataRightsReview'] else []))
        ids[canonical(entry['original_id'])].append(entry)
        for name in entry['names']:
            names[canonical(name)].append(entry)
            token = network_name_token(name)
            if (token and entry['dataRightsReview'] and config.get('format') == 'tvmaze-json'
                    and re.fullmatch(r'[A-Z]{2}', entry['context'].get('countryCode') or '')):
                names[('licensed_country_network', entry['context']['countryCode'], token)].append(entry)
    return fingerprint({'policy': REVIEW_POLICY, 'identities': generation}), ids, names


def candidates_for(channel, ids, names):
    identity, name = canonical(channel.get('epgId')), canonical(channel.get('name'))
    structured = structured_identifier(channel)
    if re.fullmatch(r'cctv\d+\+?', identity) and re.fullmatch(r'cctv\d+\+?', name) and identity != name:
        return []
    found = {}
    structured_entries = names.get(('licensed_country_network', structured['countryCode'],
        structured['networkToken']), []) if structured else []
    for entry in (ids.get(identity, []) if identity else []) + names.get(name, []) + structured_entries:
        context = entry.get('context', {})
        if context.get('countryCode') and context['countryCode'] != channel.get('countryCode'):
            continue  # A same-name source in a different/unknown country is not a proposal.
        source_names = {canonical(n) for n in entry['names']}
        id_exact = bool(identity and canonical(entry['original_id']) == identity)
        name_exact = bool(name and name in source_names)
        structured_exact = bool(structured and entry in structured_entries)
        # Known distinct numbered channels and delay variants never share a proposal.
        cctv_names = {n for n in source_names if re.fullmatch(r'cctv\d+\+?', n)}
        if re.fullmatch(r'cctv\d+\+?', name) and cctv_names and name not in cctv_names:
            continue
        if id_exact and re.fullmatch(r'cctv\d+\+?', identity) and re.fullmatch(r'cctv\d+\+?', name) and identity != name:
            continue
        delayed = lambda n: bool(re.search(r'\+\d+|\b(?:delay|timeshift)\b', n))
        if not name_exact and delayed(name) != any(delayed(n) for n in source_names):
            continue
        key = entry['source_id'] + ':' + entry['original_id']
        candidate = {
            'sourceId': entry['source_id'], 'originalChannelId': entry['original_id'],
            'originalNames': entry['names'], 'sourceUrl': json.loads(entry['configuration'])['url'],
            'identityEvidence': 'exact_id_and_name' if id_exact and name_exact else 'exact_id_only' if id_exact else 'exact_full_name_only' if name_exact else 'structured_country_identifier_requires_feed_review',
            'confidence': 0.98 if id_exact and name_exact else 0.65 if id_exact else 0.55 if name_exact else 0.45,
            'countryCode': channel.get('countryCode'), 'regionCode': channel.get('regionCode'),
            'sourceIdentityContext': context,
            'contextVerified': False, 'programmeDataRightsVerified': bool(entry.get('dataRightsReview')),
            'dataRightsReview': entry.get('dataRightsReview'),
            'sourceContentSha256': entry['content_sha256'], 'sourceFetchedAt': entry['fetched_at'],
            'metadataOrigin': entry['origin'], 'automaticallyApplied': False,
        }
        if structured_exact and not id_exact and not name_exact:
            candidate['structuredIdentifierEvidence'] = structured
        found[key] = candidate
    return sorted(found.values(), key=lambda x: (-x['confidence'], x['sourceId'], x['originalChannelId']))[:10]


def process_batch(conn, generation, ids, names, now, batch_size=5, *, reviewed_ids=None):
    if not 1 <= batch_size <= 5:
        raise EpgError('batch_size_limit')
    token = fingerprint([time.time_ns(), now])
    selected = sorted(reviewed_ids) if reviewed_ids is not None else None
    if selected == []:
        return 0
    gate = '' if selected is None else ' AND channel_id IN (' + ','.join('?' for _ in selected) + ')'
    with conn:
        rows = conn.execute('''SELECT * FROM discovery_jobs WHERE active=1 AND lease_until<=?
          AND (source_generation!=? OR (state IN ('pending','unmatched') AND next_retry<=?))
          ''' + gate + ' ORDER BY priority,channel_id LIMIT ?',
          (now, generation, now, *(selected or []), batch_size)).fetchall()
        claimed = []
        for row in rows:
            changed = conn.execute('UPDATE discovery_jobs SET lease_until=?,lease_token=? WHERE channel_id=? AND lease_until<=? AND identity_hash=?',
                (now + 120, token, row['channel_id'], now, row['identity_hash'])).rowcount
            if changed:
                claimed.append(row)
        rows = claimed
    decisions = []
    for row in rows:
        candidates = candidates_for(json.loads(row['payload']), ids, names)
        state = 'review' if candidates else 'unmatched'
        reason = ('identity_context_requires_review' if all(c['programmeDataRightsVerified'] for c in candidates)
            else 'identity_context_and_data_rights_require_review') if candidates else 'no_strict_candidate'
        encoded = json.dumps(candidates, ensure_ascii=False, sort_keys=True)
        decisions.append((row, state, reason, encoded))
    # One durable commit per five-channel batch protects the disk as well as CPU.
    with conn:
        for row, state, reason, encoded in decisions:
            # Compare-and-swap protects concurrent catalogue edits and expired leases.
            changed = conn.execute('''UPDATE discovery_jobs SET state=?,source_generation=?,next_retry=?,lease_until=0,
              lease_token=NULL,updated_at=?,candidates=?,reason=? WHERE channel_id=? AND identity_hash=? AND lease_token=?''',
                (state, generation, now + 6 * 3600, now, encoded, reason, row['channel_id'], row['identity_hash'], token)).rowcount
            if changed:
                conn.execute('INSERT INTO mapping_review_audit(channel_id,identity_hash,source_generation,checked_at,state,reason,candidates) VALUES(?,?,?,?,?,?,?)',
                    (row['channel_id'], row['identity_hash'], generation, now, state, reason, encoded))
    return len(rows)


def reviewed_targets(conn, channels):
    """Never reverse-match a newly discovered source against unknown feeds.

    Historical candidate/audit rows stay intact. Only explicit current research
    identities can receive new proposals; existing approved mappings refresh in
    their independent schedule worker and are not reopened here.
    """
    if not conn.execute("SELECT 1 FROM sqlite_master WHERE name='epg_channel_research_jobs'").fetchone():
        return set()
    by_id = {item['id']: item for item in channels}
    eligible = set()
    for row in conn.execute('SELECT channel_id,payload FROM epg_channel_research_jobs WHERE active=1 AND identity_evidence IS NOT NULL'):
        channel = by_id.get(row['channel_id'])
        if channel is None:
            continue
        target = json.loads(row['payload'])
        if (any(target.get(key) != channel.get(key) for key in ('id','name','epgId','countryCode','regionCode'))
                or target.get('routeSha256') != sorted({hashlib.sha256(r['url'].encode()).hexdigest() for r in channel.get('routes', [])})):
            continue
        eligible.add(row['channel_id'])
    if conn.execute("SELECT 1 FROM sqlite_master WHERE name='epg_mapping_approvals'").fetchone():
        eligible -= {row[0] for row in conn.execute('SELECT channel_id FROM epg_mapping_approvals WHERE revoked=0')}
    return eligible


def run(data_dir=DATA, now=None, runtime_seconds=25, clock=time.monotonic):
    now = int(time.time() if now is None else now)
    manifest, channels = load_catalog(data_dir)
    conn = database(Path(data_dir) / 'epg')
    try:
        sync_catalog(conn, manifest, channels, now)
        eligible = reviewed_targets(conn, channels)
        generation, ids, names = source_index(conn, now)
        started, processed, batches = clock(), 0, 0
        while clock() - started < runtime_seconds:
            count = process_batch(conn, generation, ids, names, now, reviewed_ids=eligible)
            if not count:
                break
            processed += count
            batches += 1
        states = {row[0]: row[1] for row in conn.execute('SELECT state,count(*) FROM discovery_jobs WHERE active=1 GROUP BY state')}
        from epg_coverage import summarize
        coverage = summarize(conn, now, Path(data_dir) / 'epg/public')
        result = {'stage': 'identity_candidate_review', 'checkedAtUtc': now,
            'catalogVersion': manifest['version'], 'catalogChannels': len(channels),
            'processedThisRun': processed, 'batchesThisRun': batches,
            'identityReviewedEligibleChannels': len(eligible), 'sourceFirstMatchingEnabled': False,
            'states': states, 'verifiedCatalogMatches': coverage['verifiedMappings'],
            'currentAndFutureChannels': coverage['currentAndFutureChannels'],
            'publishedCurrentAndFutureChannels': coverage['publishedCurrentAndFutureChannels'],
            'publishedEpgVersion': coverage['publishedEpgVersion'], 'coverageError': coverage['coverageError'],
            'sourceGeneration': generation}
        with conn:
            conn.execute('INSERT OR REPLACE INTO epg_checkpoints VALUES(?,?)', ('discovery', json.dumps(result)))
        return result
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir', type=Path, default=Path(DATA))
    parser.add_argument('--seed-existing-cache', action='store_true')
    args = parser.parse_args()
    directory = args.data_dir / 'epg'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / 'discovery.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(json.dumps({'state': 'already_running'}))
            return
        if args.seed_existing_cache:
            print(json.dumps({'seededSources': seed_cached_identities(directory, registry(), args.data_dir / 'egress-epg')}))
        print(json.dumps(run(args.data_dir), ensure_ascii=False))


if __name__ == '__main__':
    main()
