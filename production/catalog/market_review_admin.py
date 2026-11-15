"""Apply exact reviewed broadcast-market corrections to shared catalog state.

No client database, EPG database, source permissions or route URLs are edited.
The snapshot lock, route revisions, SQLite backup, compare-and-swap updates,
atomic publisher and rollback receipt protect each bounded reviewed batch.
"""
from contextlib import contextmanager
import copy
from datetime import datetime, timezone
import fcntl
import gzip
import hashlib
import json
from pathlib import Path
import sqlite3

from broadcast_market import POLICY_VERSION, load_matching_bindings, resolve_market
from channel_matching import profile, _signature
from country_names import _DATA
from publish_channel_catalog import publish, _atomic_write


def _load_catalog(data_dir):
    manifest_path = data_dir / 'channel-catalog' / 'manifest.json'
    raw = manifest_path.read_bytes()
    manifest = json.loads(raw)
    packed = (manifest_path.parent / 'snapshots' / (manifest['sha256'] + '.json.gz')).read_bytes()
    if hashlib.sha256(packed).hexdigest() != manifest['sha256']:
        raise ValueError('market_review_snapshot_hash_changed')
    return raw, manifest, json.loads(gzip.decompress(packed))


@contextmanager
def catalog_lock(data_dir):
    with (Path(data_dir) / 'catalog-process.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def _connect(data_dir, readonly=False):
    path = Path(data_dir) / 'channel_inventory.sqlite3'
    conn = sqlite3.connect('file:' + str(path.resolve()) + ('?mode=ro' if readonly else '?mode=rw'),
                           uri=True, timeout=20)
    conn.row_factory = sqlite3.Row
    return conn


def build_batch(data_dir, channel_ids, *, authorization, allow_protected_shared=False):
    """Read an exact current proposal. Caller may hold catalog_lock already."""
    if not 1 <= len(channel_ids) <= 100 or len(set(channel_ids)) != len(channel_ids):
        raise ValueError('invalid_market_review_targets')
    _, manifest, payload = _load_catalog(Path(data_dir))
    channels = {c['id']: c for c in payload['channels']}
    bindings = load_matching_bindings()
    reviews = []
    with _connect(data_dir, readonly=True) as conn:
        for identity in channel_ids:
            channel = channels[identity]
            market = resolve_market(channel, bindings)
            if market.get('status') != 'verified_edition':
                raise ValueError('market_review_unbound_or_mixed_routes')
            entity = conn.execute('SELECT * FROM catalog_channels WHERE id=?', (identity,)).fetchone()
            if not entity:
                raise ValueError('market_review_entity_missing')
            rows = conn.execute('SELECT r.* FROM routes r JOIN catalog_channel_routes m USING(digest) '
                                'WHERE m.channel_id=? AND r.blocked=0 AND r.deleted=0', (identity,)).fetchall()
            digests = sorted(hashlib.sha256(r['url'].encode()).hexdigest() for r in channel['routes'])
            if {r['digest'] for r in rows} != set(digests):
                raise ValueError('market_review_route_set_changed')
            reviews.append(dict(expectedIdentity={k: channel.get(k) for k in
                                  ('id', 'name', 'epgId', 'countryCode', 'regionCode')},
                                routeSha256=digests,
                                expectedRevisions={r['digest']: r['revision'] for r in rows},
                                expectedEntity=dict(entity),
                                newCountryCode=market['market'], evidenceUrls=market['evidenceUrls'],
                                allowProtectedShared=allow_protected_shared))
    return dict(schemaVersion=1, policyVersion=POLICY_VERSION,
                expectedManifestSha256=manifest['sha256'], authorization=authorization, reviews=reviews)


def _path(identity, categories):
    result, seen = [], set()
    while identity:
        if identity in seen or identity not in categories:
            raise ValueError('market_review_category_invalid')
        seen.add(identity)
        item = categories[identity]
        result.insert(0, item['name'])
        identity = item['parentId']
    return result


def _category(path, categories):
    known = {tuple(_path(k, categories)): k for k in categories}
    parent = None
    for depth in range(1, len(path) + 1):
        prefix = tuple(path[:depth])
        identity = known.get(prefix)
        if identity is None:
            identity = 'category-' + hashlib.sha256(' / '.join(prefix).encode()).hexdigest()[:24]
            categories[identity] = dict(id=identity, parentId=parent, name=prefix[-1], sortOrder=10)
            known[prefix] = identity
        parent = identity
    return parent


def apply_batch_locked(data_dir, batch, *, publisher=publish, now=None):
    """Caller owns catalog_lock. No normal worker calls this admin operation."""
    data_dir = Path(data_dir)
    if (batch.get('schemaVersion') != 1 or batch.get('policyVersion') != POLICY_VERSION
            or not isinstance(batch.get('authorization'), str) or not batch['authorization'].strip()
            or not 1 <= len(batch.get('reviews', [])) <= 100):
        raise ValueError('invalid_market_review_batch')
    old_manifest_raw, old_manifest, original = _load_catalog(data_dir)
    if old_manifest['sha256'] != batch['expectedManifestSha256']:
        raise ValueError('market_review_manifest_changed')
    payload = copy.deepcopy(original)
    by_id = {c['id']: c for c in payload['channels']}
    categories = {c['id']: c for c in payload['categories']}
    bindings = load_matching_bindings()
    now = now or datetime.now(timezone.utc)
    stamp = now.strftime('%Y%m%dT%H%M%S%fZ')
    backup = data_dir / 'market-review-backups' / stamp
    backup.mkdir(parents=True, mode=0o700)
    (backup / 'manifest.json').write_bytes(old_manifest_raw)
    queue_path = data_dir / 'broadcast-market-review-queue.json'
    old_queue = queue_path.read_bytes() if queue_path.exists() else None
    if old_queue is not None:
        (backup / 'broadcast-market-review-queue.json').write_bytes(old_queue)
    (backup / 'review-batch.json').write_text(json.dumps(batch, ensure_ascii=False, indent=2))
    receipt = dict(policyVersion=POLICY_VERSION, authorization=batch['authorization'],
                   oldManifest=old_manifest, changes=[], epgMappingEdits=0,
                   routeUrlEdits=0, privateClientEdits=0, backupDirectory=str(backup))
    conn = _connect(data_dir)
    with sqlite3.connect(backup / 'channel_inventory.sqlite3') as saved:
        conn.backup(saved)
    try:
        conn.execute('BEGIN IMMEDIATE')
        conn.execute('CREATE TABLE IF NOT EXISTS catalog_broadcast_market_reviews('
                     'review_id TEXT PRIMARY KEY,channel_id TEXT NOT NULL,reviewed_at TEXT NOT NULL,'
                     'old_entity TEXT NOT NULL,new_entity TEXT NOT NULL,evidence TEXT NOT NULL)')
        for review in batch['reviews']:
            expected = review['expectedIdentity']
            target = by_id.get(expected['id'])
            if not target or any(target.get(k) != v for k, v in expected.items()):
                raise ValueError('market_review_identity_changed')
            hashes = {hashlib.sha256(r['url'].encode()).hexdigest() for r in target['routes']}
            if hashes != set(review['routeSha256']):
                raise ValueError('market_review_routes_changed')
            fact = resolve_market(target, bindings)
            market = review['newCountryCode']
            if fact.get('market') != market or fact.get('status') != 'verified_edition':
                raise ValueError('market_review_unproven_market')
            old_path = _path(target['categoryId'], categories)
            if len(old_path) < 2 or old_path[0] != '国际' or target.get('regionCode') is not None:
                raise ValueError('market_review_hierarchy_requires_review')
            label = _DATA['names'][market.lower()]
            new_path = ['国际', label, *old_path[2:]]
            entity = conn.execute('SELECT * FROM catalog_channels WHERE id=?', (target['id'],)).fetchone()
            if not entity or dict(entity) != review['expectedEntity']:
                raise ValueError('market_review_entity_changed')
            entity_metadata = json.loads(entity['metadata'])
            if any(entity_metadata.get(k) != v for k, v in expected.items()):
                raise ValueError('market_review_entity_identity_changed')
            rows = conn.execute('SELECT r.*,m.state AS match_state FROM routes r '
                                'JOIN catalog_channel_routes m USING(digest) WHERE m.channel_id=? '
                                'AND r.blocked=0 AND r.deleted=0', (target['id'],)).fetchall()
            if {r['digest'] for r in rows} != hashes:
                raise ValueError('market_review_inventory_members_changed')
            if any(r['revision'] != review['expectedRevisions'].get(r['digest'])
                   or r['match_state'] != 'assigned' or r['merge_id'] or r['transferred'] for r in rows):
                raise ValueError('market_review_route_revision_or_ownership_changed')
            if any(r['manual_category'] or r['manual_name'] for r in rows) and review.get('allowProtectedShared') is not True:
                raise ValueError('market_review_shared_protection_requires_explicit_review')
            parts = entity['group_name'].split(' / ')
            if len(parts) < 2 or parts[0] != '国际':
                raise ValueError('market_review_entity_hierarchy_changed')
            new_group = ' / '.join(['国际', label, *parts[2:]])
            target['countryCode'] = market
            target['categoryId'] = _category(new_path, categories)
            if 'categoryIds' in target:
                target['categoryIds'] = list(dict.fromkeys(_category(
                    ['国际', label, *_path(cid, categories)[2:]], categories)
                    for cid in target['categoryIds']))
            entity_metadata.update(countryCode=market, categoryId=target['categoryId'])
            updated_profile = profile(entity_metadata['name'], entity_metadata['epgId'], new_group,
                                      market, entity_metadata['regionCode'], True, rows[0]['url'])
            old_rows, new_rows = [], []
            for row in rows:
                if row['group_name'] != entity['group_name']:
                    raise ValueError('market_review_route_group_changed')
                old_rows.append({k: row[k] for k in ('digest', 'group_name', 'revision')})
                conn.execute('UPDATE routes SET group_name=?,revision=revision+1 WHERE digest=? AND revision=?',
                             (new_group, row['digest'], row['revision']))
                new_row = conn.execute('SELECT * FROM routes WHERE digest=?', (row['digest'],)).fetchone()
                evidence = [r[0] for r in conn.execute('SELECT group_name FROM public_source_routes '
                                                      'WHERE digest=? AND active=1 ORDER BY source_id', (row['digest'],))]
                conn.execute('UPDATE catalog_channel_routes SET signature=?,reason=? WHERE digest=?',
                             (_signature(new_row, evidence), 'reviewed-broadcast-market', row['digest']))
                new_rows.append({k: new_row[k] for k in ('digest', 'group_name', 'revision')})
                for route in target['routes']:
                    if hashlib.sha256(route['url'].encode()).hexdigest() == row['digest']:
                        route['revision'] = new_row['revision']
            new_entity = dict(id=target['id'], metadata=json.dumps(entity_metadata, ensure_ascii=False),
                              group_name=new_group, profile=json.dumps(updated_profile))
            conn.execute('UPDATE catalog_channels SET metadata=?,group_name=?,profile=? WHERE id=?',
                         (new_entity['metadata'], new_group, new_entity['profile'], target['id']))
            change = dict(channelId=target['id'], oldCountryCode=expected['countryCode'],
                          newCountryCode=market, oldPath=old_path, newPath=new_path,
                          oldEntity=dict(entity), newEntity=new_entity, oldRoutes=old_rows, newRoutes=new_rows,
                          reviewedProtectedShared=review.get('allowProtectedShared') is True,
                          evidenceUrls=fact['evidenceUrls'])
            review_id = hashlib.sha256(json.dumps(change, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
            conn.execute('INSERT INTO catalog_broadcast_market_reviews VALUES(?,?,?,?,?,?)',
                         (review_id, target['id'], now.isoformat(), json.dumps(dict(entity), ensure_ascii=False),
                          json.dumps(new_entity, ensure_ascii=False), json.dumps(change, ensure_ascii=False)))
            receipt['changes'].append(change)
        payload['categories'] = list(categories.values())
        payload['version'] = now.strftime('%Y-%m-%dT%H:%M:%S.%fZ')
        receipt['newManifest'] = publisher(payload, data_dir)
        conn.commit()
        receipt['state'] = 'applied'
    except BaseException:
        conn.rollback()
        _atomic_write(data_dir / 'channel-catalog' / 'manifest.json', old_manifest_raw)
        if old_queue is not None:
            _atomic_write(queue_path, old_queue)
        elif queue_path.exists():
            queue_path.unlink()
        raise
    finally:
        conn.close()
    (backup / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2))
    return receipt


def apply_batch(data_dir, batch, **kwargs):
    with catalog_lock(data_dir):
        return apply_batch_locked(data_dir, batch, **kwargs)
