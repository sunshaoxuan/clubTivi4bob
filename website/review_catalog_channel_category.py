"""Explicit single-channel category review for the persistent inventory entity.

The caller owns catalog-process.lock and an exact current public snapshot.
No network, classifier, identity/route edits, EPG mapping or permission writes.
This administrative function is never invoked by an automatic discovery job.
"""
import hashlib
import json

from source_registry import validate_public_url

FIELDS=('id','name','epgId','countryCode','regionCode')


def category_path(identity,categories):
    result=[];seen=set()
    while identity:
        if identity in seen or identity not in categories or len(seen)>=8:
            raise ValueError('invalid_review_category')
        seen.add(identity);item=categories[identity]
        result.insert(0,item['name']);identity=item['parentId']
    return result


def correct_category(conn,payload,expected_identity,expected_routes,old_path,new_path,
                     inventory_names,evidence_urls,now,*,restore_inventory_geography=False):
    # This opt-in restores a named international geography already present in
    # every original route. It never guesses a country from channel names and
    # does not authorize a programme feed. Geographic fields are reviewed by
    # the separate exact-identity/route-bound metadata registry.
    geographic_restore = (restore_inventory_geography is True
        and isinstance(old_path,list) and len(old_path)==2 and old_path[0]=='中国'
        and isinstance(new_path,list) and len(new_path)==3 and new_path[0]=='国际'
        and new_path[-1]==old_path[-1])
    if (not isinstance(expected_identity,dict) or set(expected_identity)!=set(FIELDS)
            or type(now) is not int or now<0
            or not isinstance(expected_routes,list) or not 1<=len(expected_routes)<=100
            or len(set(expected_routes))!=len(expected_routes)
            or not isinstance(old_path,list) or not 1<=len(old_path)<8
            or type(restore_inventory_geography) is not bool
            or not isinstance(new_path,list) or not (geographic_restore
                or len(new_path)==len(old_path)+1 and new_path[:-1]==old_path)
            or any(not isinstance(n,str) or not 1<=len(n)<=64 for n in old_path+new_path)
            or not isinstance(inventory_names,list) or not inventory_names or len(inventory_names)>10
            or not isinstance(evidence_urls,list) or not 1<=len(evidence_urls)<=5):
        raise ValueError('invalid_category_review')
    for url in evidence_urls:validate_public_url(url)
    matches=[c for c in payload['channels'] if c['id']==expected_identity['id']]
    if len(matches)!=1 or any(matches[0].get(k)!=v for k,v in expected_identity.items()):
        raise ValueError('category_review_identity_changed')
    target=matches[0]
    hashes={hashlib.sha256(r['url'].encode()).hexdigest() for r in target['routes']}
    if hashes!=set(expected_routes):raise ValueError('category_review_routes_changed')
    categories={c['id']:c for c in payload['categories']}
    current_path=category_path(target['categoryId'],categories)
    if current_path not in (old_path,new_path):raise ValueError('category_review_context_changed')
    group=' / '.join(new_path);previous_group=' / '.join(old_path)
    known={tuple(category_path(c['id'],categories)):c['id'] for c in categories.values()}
    category_id=known.get(tuple(new_path),'category-'+hashlib.sha256(group.encode()).hexdigest()[:24])
    audit_evidence={'expectedIdentity':expected_identity,'routeSha256':sorted(hashes),
        'oldPath':old_path,'newPath':new_path,'evidenceUrls':evidence_urls,
        'restoredOriginalInventoryGeography':geographic_restore,
        'programmeFeedIdentityApproved':False,'newEpgMappings':0,'newDataGrants':0}
    review_id=hashlib.sha256(json.dumps(audit_evidence,sort_keys=True,ensure_ascii=False).encode()).hexdigest()
    if conn.in_transaction:raise ValueError('category_review_requires_own_transaction')
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        row=conn.execute('SELECT * FROM catalog_channels WHERE id=?',(expected_identity['id'],)).fetchone()
        if row is None:raise ValueError('category_review_entity_missing')
        metadata=json.loads(row['metadata'])
        if any(metadata.get(k)!=v for k,v in expected_identity.items()) or row['group_name'] not in (previous_group,group):
            raise ValueError('category_review_entity_changed')
        for digest in hashes:
            route=conn.execute('''SELECT r.name,r.group_name,r.manual_category,r.manual_name,
              r.deleted,r.blocked,m.channel_id,m.state FROM routes r
              JOIN catalog_channel_routes m ON m.digest=r.digest WHERE r.digest=?''',(digest,)).fetchone()
            if (route is None or route['name'] not in inventory_names or route['group_name']!=group
                    or any(route[k] for k in ('manual_category','manual_name','deleted','blocked'))
                    or route['channel_id']!=expected_identity['id'] or route['state']!='assigned'):
                raise ValueError('category_review_route_or_manual_guard')
        conn.execute('''CREATE TABLE IF NOT EXISTS catalog_channel_metadata_review_audit(
          review_id TEXT PRIMARY KEY,channel_id TEXT NOT NULL,reviewed_at INTEGER NOT NULL,
          previous_entity TEXT NOT NULL,new_entity TEXT NOT NULL,evidence TEXT NOT NULL)''')
        old={k:row[k] for k in ('id','metadata','group_name','profile')}
        if row['group_name']==group and metadata.get('categoryId')==category_id:
            return {'applied':False,'channelId':expected_identity['id'],'categoryPath':new_path,
                    'reason':'already_applied','reviewId':review_id}
        metadata['categoryId']=category_id
        new={**old,'metadata':json.dumps(metadata,ensure_ascii=False),'group_name':group}
        changed=conn.execute('''UPDATE catalog_channels SET metadata=?,group_name=? WHERE id=?
          AND metadata=? AND group_name=? AND profile=?''',
          (new['metadata'],group,row['id'],row['metadata'],row['group_name'],row['profile'])).rowcount
        if changed!=1:raise ValueError('category_review_entity_changed')
        conn.execute('INSERT INTO catalog_channel_metadata_review_audit VALUES(?,?,?,?,?,?)',
          (review_id,row['id'],now,json.dumps(old,ensure_ascii=False),json.dumps(new,ensure_ascii=False),
           json.dumps(audit_evidence,ensure_ascii=False)))
    return {'applied':True,'channelId':expected_identity['id'],'oldPath':old_path,
            'categoryPath':new_path,'reviewId':review_id,'changedEntities':1,
            'routeEdits':0,'epgMappingEdits':0,'programmeFeedIdentityApproved':False}
