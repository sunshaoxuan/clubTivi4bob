"""Exact shared-channel review holds at SQLite and publication boundaries.

Automatic writes retain geography while health/other fields continue. A manual
classify event has its own audited override function; a legacy manual flag is
never an authorization token. Context changes stay held and require review.
"""
import copy
import hashlib
import json
from pathlib import Path
import time

TABLE = 'catalog_market_review_holds'


def _table(conn, name):
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def install_schema(conn):
    if _table(conn, TABLE):
        return
    if not conn.in_transaction: conn.execute('BEGIN IMMEDIATE')
    conn.execute('CREATE TABLE catalog_market_review_holds(channel_id TEXT PRIMARY KEY,expected_identity TEXT NOT NULL,frozen_metadata TEXT NOT NULL,frozen_profile TEXT NOT NULL,frozen_group TEXT NOT NULL,published_path TEXT NOT NULL,status TEXT NOT NULL,created_at INTEGER NOT NULL,manual_event_id TEXT)')
    conn.execute('CREATE TABLE catalog_market_hold_routes(digest TEXT PRIMARY KEY,channel_id TEXT NOT NULL,expected_context TEXT NOT NULL,frozen_group TEXT NOT NULL)')
    conn.execute('CREATE TABLE catalog_market_hold_events(id INTEGER PRIMARY KEY,channel_id TEXT,kind TEXT NOT NULL,detail TEXT NOT NULL,created_at INTEGER NOT NULL)')
    conn.execute('CREATE TABLE catalog_market_hold_control(name TEXT PRIMARY KEY,value TEXT NOT NULL)')
    conn.execute('CREATE TABLE catalog_market_verified_releases(channel_id TEXT PRIMARY KEY,queue_sha256 TEXT NOT NULL,evidence TEXT NOT NULL,reviewed_at INTEGER NOT NULL)')
    conn.execute('CREATE UNIQUE INDEX market_hold_event_dedupe ON catalog_market_hold_events(channel_id,kind,detail)')
    entity_guard = '''CREATE TRIGGER {name} AFTER {operation} ON catalog_channels
      WHEN EXISTS(SELECT 1 FROM catalog_market_review_holds h WHERE h.channel_id=NEW.id AND (
        json_extract(NEW.metadata,'$.countryCode') IS NOT json_extract(h.frozen_metadata,'$.countryCode') OR
        json_extract(NEW.metadata,'$.regionCode') IS NOT json_extract(h.frozen_metadata,'$.regionCode') OR
        json_extract(NEW.metadata,'$.categoryId') IS NOT json_extract(h.frozen_metadata,'$.categoryId') OR
        json_extract(NEW.profile,'$.country') IS NOT json_extract(h.frozen_profile,'$.country') OR
        json_extract(NEW.profile,'$.region') IS NOT json_extract(h.frozen_profile,'$.region') OR NEW.group_name IS NOT h.frozen_group))
      BEGIN
        INSERT INTO catalog_market_hold_events(channel_id,kind,detail,created_at) SELECT NEW.id,'blocked_entity_geography',NEW.group_name,unixepoch() WHERE NOT EXISTS(SELECT 1 FROM catalog_market_hold_events WHERE channel_id=NEW.id AND kind='blocked_entity_geography' AND detail=NEW.group_name);
        UPDATE catalog_channels SET
          metadata=json_set(NEW.metadata,'$.countryCode',(SELECT json_extract(frozen_metadata,'$.countryCode') FROM catalog_market_review_holds WHERE channel_id=NEW.id),'$.regionCode',(SELECT json_extract(frozen_metadata,'$.regionCode') FROM catalog_market_review_holds WHERE channel_id=NEW.id),'$.categoryId',(SELECT json_extract(frozen_metadata,'$.categoryId') FROM catalog_market_review_holds WHERE channel_id=NEW.id)),
          profile=json_set(NEW.profile,'$.country',(SELECT json_extract(frozen_profile,'$.country') FROM catalog_market_review_holds WHERE channel_id=NEW.id),'$.region',(SELECT json_extract(frozen_profile,'$.region') FROM catalog_market_review_holds WHERE channel_id=NEW.id)),
          group_name=(SELECT frozen_group FROM catalog_market_review_holds WHERE channel_id=NEW.id) WHERE id=NEW.id;
      END'''
    for name,operation in [('market_hold_entity_geo','UPDATE OF metadata,profile,group_name'),('market_hold_entity_insert','INSERT')]:
        conn.execute(entity_guard.format(name=name,operation=operation))
    context_guard = '''CREATE TRIGGER {name} AFTER {operation} ON catalog_channels
      WHEN EXISTS(SELECT 1 FROM catalog_market_review_holds h WHERE h.channel_id=NEW.id AND (
        json_extract(NEW.metadata,'$.name') IS NOT json_extract(h.expected_identity,'$.name') OR
        json_extract(NEW.metadata,'$.epgId') IS NOT json_extract(h.expected_identity,'$.epgId')))
      BEGIN UPDATE catalog_market_review_holds SET status='context_changed' WHERE channel_id=NEW.id; END'''
    for name,operation in [('market_hold_entity_context','UPDATE OF metadata'),('market_hold_entity_context_insert','INSERT')]:
        conn.execute(context_guard.format(name=name,operation=operation))
    conn.execute('''CREATE TRIGGER market_hold_route_group AFTER UPDATE OF group_name ON routes
      WHEN EXISTS(SELECT 1 FROM catalog_market_hold_routes h WHERE h.digest=NEW.digest AND NEW.group_name IS NOT h.frozen_group)
      BEGIN
        INSERT OR IGNORE INTO catalog_market_hold_events(channel_id,kind,detail,created_at) SELECT h.channel_id,'blocked_route_category',NEW.group_name,unixepoch() FROM catalog_market_hold_routes h WHERE h.digest=NEW.digest AND NOT EXISTS(SELECT 1 FROM catalog_market_hold_events e WHERE e.channel_id=h.channel_id AND e.kind='blocked_route_category' AND e.detail=NEW.group_name);
        UPDATE routes SET group_name=(SELECT frozen_group FROM catalog_market_hold_routes WHERE digest=NEW.digest) WHERE digest=NEW.digest;
      END''')
    conn.execute('''CREATE TRIGGER market_hold_route_context AFTER UPDATE OF name,url,epg_id,revision,blocked,deleted ON routes
      WHEN EXISTS(SELECT 1 FROM catalog_market_hold_routes h WHERE h.digest=NEW.digest AND (
        NEW.name IS NOT json_extract(h.expected_context,'$.name') OR NEW.url IS NOT json_extract(h.expected_context,'$.url') OR
        NEW.epg_id IS NOT json_extract(h.expected_context,'$.epg_id') OR NEW.revision IS NOT json_extract(h.expected_context,'$.revision') OR NEW.blocked OR NEW.deleted))
      BEGIN UPDATE catalog_market_review_holds SET status='context_changed' WHERE channel_id=(SELECT channel_id FROM catalog_market_hold_routes WHERE digest=NEW.digest); END''')
    # Replacement of a known route retains its hold and rechecks its context.
    for source, target, operation in [
        ('market_hold_route_group', 'market_hold_route_group_insert', 'INSERT'),
        ('market_hold_route_context', 'market_hold_route_context_insert', 'INSERT')]:
        sql = conn.execute("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", (source,)).fetchone()[0]
        sql = sql.replace('CREATE TRIGGER '+source, 'CREATE TRIGGER '+target)
        if source.endswith('group'):
            sql = sql.replace('AFTER UPDATE OF group_name', 'AFTER INSERT')
        else:
            sql = sql.replace('AFTER UPDATE OF name,url,epg_id,revision,blocked,deleted', 'AFTER INSERT')
        conn.execute(sql)
    for operation in ('INSERT', 'UPDATE'):
        conn.execute(f'''CREATE TRIGGER market_hold_assignment_{operation.lower()} AFTER {operation} ON catalog_channel_routes
          WHEN EXISTS(SELECT 1 FROM catalog_market_hold_routes WHERE digest=NEW.digest) OR EXISTS(SELECT 1 FROM catalog_market_review_holds WHERE channel_id=NEW.channel_id)
          BEGIN
            UPDATE catalog_market_review_holds SET status='context_changed' WHERE channel_id=(SELECT channel_id FROM catalog_market_hold_routes WHERE digest=NEW.digest AND channel_id IS NOT NEW.channel_id);
            UPDATE catalog_market_review_holds SET status='context_changed' WHERE channel_id=NEW.channel_id AND NOT EXISTS(SELECT 1 FROM catalog_market_hold_routes WHERE digest=NEW.digest);
            INSERT OR IGNORE INTO catalog_market_hold_routes(digest,channel_id,expected_context,frozen_group)
              SELECT r.digest,NEW.channel_id,json_object('name',r.name,'url',r.url,'epg_id',r.epg_id,'revision',r.revision,'match_state',NEW.state),h.frozen_group FROM routes r JOIN catalog_market_review_holds h ON h.channel_id=NEW.channel_id WHERE r.digest=NEW.digest AND NOT EXISTS(SELECT 1 FROM catalog_market_hold_routes WHERE digest=NEW.digest);
            UPDATE routes SET group_name=(SELECT frozen_group FROM catalog_market_hold_routes WHERE digest=NEW.digest) WHERE digest=NEW.digest AND EXISTS(SELECT 1 FROM catalog_market_hold_routes WHERE digest=NEW.digest);
            UPDATE catalog_channel_routes SET channel_id=(SELECT channel_id FROM catalog_market_hold_routes WHERE digest=NEW.digest),state=coalesce((SELECT json_extract(expected_context,'$.match_state') FROM catalog_market_hold_routes WHERE digest=NEW.digest),'pending'),reason='market-review-held' WHERE digest=NEW.digest AND EXISTS(SELECT 1 FROM catalog_market_hold_routes WHERE digest=NEW.digest) AND channel_id IS NOT (SELECT channel_id FROM catalog_market_hold_routes WHERE digest=NEW.digest);
          END''')


def refresh_holds(conn, data_dir):
    """Import new queued identities before an inventory transaction can write."""
    if not _table(conn, 'catalog_channels') or not _table(conn, 'catalog_channel_routes'):
        return 0
    install_schema(conn)
    queue_path = Path(data_dir) / 'broadcast-market-review-queue.json'
    if not queue_path.is_file():
        return 0
    raw = queue_path.read_bytes()
    signature = hashlib.sha256(raw).hexdigest()
    previous = conn.execute("SELECT value FROM catalog_market_hold_control WHERE name='queue_sha256'").fetchone()
    if previous and previous[0] == signature:
        return 0
    queue = json.loads(raw)
    added = 0
    for finding in queue.get('reviewFindings', []):
        identity = finding['channelId']
        released=conn.execute('SELECT queue_sha256 FROM catalog_market_verified_releases WHERE channel_id=?',(identity,)).fetchone()
        if released and released[0]==signature:continue
        if conn.execute('SELECT 1 FROM catalog_market_review_holds WHERE channel_id=?', (identity,)).fetchone():
            continue
        entity = conn.execute('SELECT * FROM catalog_channels WHERE id=?', (identity,)).fetchone()
        if not entity:
            continue
        metadata = json.loads(entity['metadata'])
        current_identity = {k: metadata.get(k) for k in ('id','name','epgId','countryCode','regionCode')}
        expected = finding.get('expectedIdentity') or current_identity
        context_matches = all(metadata.get(k) == expected.get(k) for k in ('name','epgId','countryCode','regionCode'))
        status = 'pending' if context_matches and metadata.get('name') == finding['name'] and metadata.get('countryCode') == finding.get('countryCode') else 'context_changed'
        conn.execute('INSERT INTO catalog_market_review_holds VALUES(?,?,?,?,?,?,?,?,NULL)',
                     (identity,json.dumps(expected),entity['metadata'],entity['profile'],entity['group_name'],json.dumps(finding['categoryPath'],ensure_ascii=False),status,int(time.time())))
        for row in conn.execute('SELECT r.*,m.state AS match_state FROM routes r JOIN catalog_channel_routes m USING(digest) WHERE m.channel_id=? AND r.blocked=0 AND r.deleted=0', (identity,)).fetchall():
            context = {k:row[k] for k in ('name','url','epg_id','revision','match_state')}
            conn.execute('INSERT OR IGNORE INTO catalog_market_hold_routes VALUES(?,?,?,?)',
                         (row['digest'],identity,json.dumps(context),row['group_name']))
        added += 1
    conn.execute("INSERT OR REPLACE INTO catalog_market_hold_control VALUES('queue_sha256',?)", (signature,))
    return added


def route_hold(conn, digest):
    if not _table(conn, TABLE):
        return None
    return conn.execute('SELECT h.* FROM catalog_market_review_holds h JOIN catalog_market_hold_routes r ON r.channel_id=h.channel_id WHERE r.digest=?', (digest,)).fetchone()


def channel_held(conn, identity):
    return _table(conn, TABLE) and conn.execute('SELECT 1 FROM catalog_market_review_holds WHERE channel_id=?', (identity,)).fetchone() is not None


def resolve_held_route(matcher, row):
    hold = route_hold(matcher.conn, row['digest'])
    if not hold or hold['channel_id'] not in matcher.entities:
        return None
    identity = hold['channel_id']
    stored = matcher.conn.execute('SELECT * FROM catalog_channels WHERE id=?', (identity,)).fetchone()
    metadata, p = json.loads(stored['metadata']), json.loads(stored['profile'])
    # Other fields remain as persisted; automatic geographic inferences are not
    # consulted for this exact pending route, including cached AI responses.
    matcher.entities[identity] = dict(metadata=metadata,group=stored['group_name'],profile=p)
    from channel_matching import _signature
    signature = _signature(row, matcher.category_evidence.get(row['digest'], ()))
    current=matcher.conn.execute('SELECT state FROM catalog_channel_routes WHERE digest=?',(row['digest'],)).fetchone()
    state=current['state'] if current else 'pending'
    matcher.conn.execute("INSERT INTO catalog_channel_routes VALUES(?,?,?,'market-review-held',?) ON CONFLICT(digest) DO UPDATE SET channel_id=excluded.channel_id,state=excluded.state,reason='market-review-held',signature=excluded.signature", (row['digest'],identity,state,signature))
    matcher.assignments[row['digest']] = dict(channel_id=identity,state=state,reason='market-review-held',signature=signature)
    return identity


def manual_category_override(conn, digest, group, event_id):
    """Only the explicit classify action calls this, never a manual flag check."""
    hold = route_hold(conn, digest)
    if not hold:
        return False
    from country_names import _DATA, normalize_country_name
    parts = group.split(' / ')
    metadata, p = json.loads(hold['frozen_metadata']), json.loads(hold['frozen_profile'])
    country = metadata.get('countryCode')
    if parts[0] == '中国': country = 'CN'
    elif len(parts) > 1 and parts[0] == '国际':
        label = normalize_country_name(parts[1])
        country = next(('GB' if k == 'uk' else k.upper() for k,v in _DATA['names'].items() if v == label), country)
    if country != metadata.get('countryCode'):
        metadata['regionCode'] = None
        p['region'] = None
    metadata['countryCode'], p['country'] = country, country
    from catalog_taxonomy import classified_path
    published_path = classified_path(parts, metadata)
    category_id = 'category-'+hashlib.sha256(' / '.join(published_path).encode()).hexdigest()[:24]
    import gzip
    directory = Path(conn.execute('PRAGMA database_list').fetchone()[2]).parent
    try:
        manifest=json.loads((directory/'channel-catalog/manifest.json').read_text())
        payload=json.loads(gzip.decompress((directory/'channel-catalog/snapshots'/(manifest['sha256']+'.json.gz')).read_bytes()))
        cats={c['id']:c for c in payload['categories']}
        def path_for(cid):
            c=cats[cid]
            return (path_for(c['parentId']) if c['parentId'] else [])+[c['name']]
        category_id=next((cid for cid in cats if path_for(cid)==published_path),category_id)
    except (OSError,KeyError,ValueError):
        pass
    metadata['categoryId']=category_id
    conn.execute("UPDATE catalog_market_review_holds SET frozen_metadata=?,frozen_profile=?,frozen_group=?,published_path=?,status='manual_override_pending_evidence',manual_event_id=? WHERE channel_id=?", (json.dumps(metadata,ensure_ascii=False),json.dumps(p),group,json.dumps(published_path,ensure_ascii=False),event_id,hold['channel_id']))
    conn.execute('UPDATE catalog_market_hold_routes SET frozen_group=? WHERE channel_id=?', (group,hold['channel_id']))
    row=conn.execute('SELECT name,url,epg_id,revision FROM routes WHERE digest=?',(digest,)).fetchone()
    if row:
        context=dict(row);context['revision']+=1
        member=conn.execute('SELECT state FROM catalog_channel_routes WHERE digest=?',(digest,)).fetchone()
        context['match_state']=member['state'] if member else 'pending'
        conn.execute('UPDATE catalog_market_hold_routes SET expected_context=? WHERE digest=?',(json.dumps(context),digest))
    conn.execute('UPDATE catalog_channels SET metadata=?,profile=?,group_name=? WHERE id=?', (json.dumps(metadata,ensure_ascii=False),json.dumps(p),group,hold['channel_id']))
    conn.execute('INSERT OR IGNORE INTO catalog_market_hold_events(channel_id,kind,detail,created_at) VALUES(?,?,?,?)', (hold['channel_id'],'explicit_manual_category',json.dumps({'eventId':event_id,'group':group},ensure_ascii=False),int(time.time())))
    return True


def preserve_public_geography(payload, data_dir, *, active_conn=None):
    """Final barrier for worker proposals built from stale in-memory objects."""
    import sqlite3
    db = Path(data_dir) / 'channel_inventory.sqlite3'
    if not db.is_file(): return payload
    conn = active_conn or sqlite3.connect('file:'+str(db.resolve())+'?mode=ro',uri=True)
    conn.row_factory = sqlite3.Row
    try:
        if not _table(conn, TABLE): return payload
        holds = {r['channel_id']:dict(r) for r in conn.execute('SELECT * FROM catalog_market_review_holds')}
        owners = {r['digest']:r['channel_id'] for r in conn.execute('SELECT digest,channel_id FROM catalog_market_hold_routes')}
        released={r['channel_id']:r['queue_sha256'] for r in conn.execute('SELECT channel_id,queue_sha256 FROM catalog_market_verified_releases')}
    finally:
        if active_conn is None:conn.close()
    queue_path=Path(data_dir)/'broadcast-market-review-queue.json'
    if queue_path.is_file():
        raw=queue_path.read_bytes();queue_sha=hashlib.sha256(raw).hexdigest()
        for finding in json.loads(raw).get('reviewFindings',[]):
            identity=finding['channelId']
            if identity not in holds and released.get(identity)!=queue_sha:
                expected=finding.get('expectedIdentity') or {'countryCode':finding.get('countryCode'),'regionCode':None}
                holds[identity]={'frozen_metadata':json.dumps(expected),'published_path':json.dumps(finding['categoryPath'])}
    if not holds: return payload
    result = copy.deepcopy(payload)
    from route_identity import canonical_route_url
    kept, recovered = [], {}
    for channel in result['channels']:
        remaining=[]
        for route in channel['routes']:
            digest=hashlib.sha256(canonical_route_url(route['url']).encode()).hexdigest()
            owner=owners.get(digest)
            if owner and owner!=channel['id']:
                recovered.setdefault(owner,[]).append(route)
            else:remaining.append(route)
        channel['routes']=remaining
        if remaining:kept.append(channel)
    by_id={c['id']:c for c in kept}
    for identity,routes in recovered.items():
        target=by_id.get(identity)
        if target is None:
            target={**json.loads(holds[identity]['frozen_metadata']),'routes':[]}
            kept.append(target);by_id[identity]=target
        target['routes'].extend(routes)
    result['channels']=kept
    categories = {c['id']:c for c in result['categories']}
    paths = {}
    def path_for(cid):
        c=categories[cid]
        return (path_for(c['parentId']) if c['parentId'] else [])+[c['name']]
    for cid in categories:paths[tuple(path_for(cid))]=cid
    def category(path):
        parent=None
        for i in range(1,len(path)+1):
            prefix=tuple(path[:i]);cid=paths.get(prefix)
            if not cid:
                cid='category-'+hashlib.sha256(' / '.join(prefix).encode()).hexdigest()[:24]
                categories[cid]=dict(id=cid,parentId=parent,name=prefix[-1],sortOrder=10);paths[prefix]=cid
            parent=cid
        return parent
    for channel in result['channels']:
        hold=holds.get(channel['id'])
        if not hold:continue
        frozen=json.loads(hold['frozen_metadata'])
        channel['countryCode'],channel['regionCode']=frozen.get('countryCode'),frozen.get('regionCode')
        channel['categoryId']=category(json.loads(hold['published_path']))
    result['categories']=list(categories.values())
    return result


def release_verified_hold(conn, data_dir, channel_id, market, expected_digests, evidence):
    """Official identity/route-verified admin approval, distinct from manual UI."""
    if not channel_held(conn, channel_id): return False
    from broadcast_market import load_matching_bindings, resolve_market
    rows=conn.execute('SELECT r.* FROM routes r JOIN catalog_channel_routes m USING(digest) WHERE m.channel_id=? AND r.blocked=0 AND r.deleted=0',(channel_id,)).fetchall()
    if {r['digest'] for r in rows}!=set(expected_digests):raise ValueError('market_hold_release_context_changed')
    fact=resolve_market({'routes':[{'url':r['url']} for r in rows]},load_matching_bindings())
    if fact.get('status')!='verified_edition' or fact.get('market')!=market:raise ValueError('market_hold_release_unproven')
    old=dict(conn.execute('SELECT * FROM catalog_market_review_holds WHERE channel_id=?',(channel_id,)).fetchone())
    queue=Path(data_dir)/'broadcast-market-review-queue.json'
    queue_sha=hashlib.sha256(queue.read_bytes()).hexdigest() if queue.exists() else ''
    detail=json.dumps({'oldHold':old,'market':market,'routeSha256':sorted(expected_digests),'evidenceUrls':fact['evidenceUrls'],'approval':evidence},ensure_ascii=False,sort_keys=True)
    conn.execute('INSERT OR REPLACE INTO catalog_market_verified_releases VALUES(?,?,?,?)',(channel_id,queue_sha,detail,int(time.time())))
    conn.execute('INSERT OR IGNORE INTO catalog_market_hold_events(channel_id,kind,detail,created_at) VALUES(?,?,?,?)',(channel_id,'official_market_review_released',detail,int(time.time())))
    conn.execute('DELETE FROM catalog_market_hold_routes WHERE channel_id=?',(channel_id,))
    conn.execute('DELETE FROM catalog_market_review_holds WHERE channel_id=?',(channel_id,))
    return True
