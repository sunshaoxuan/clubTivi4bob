"""Conservative repair of identities split only by an automatic genre label.

This never uses a genre as evidence that two differently named services match.
Unknown geography, conflicting EPG/region metadata and manual identity decisions remain
separate. Existing channel IDs and every route are retained where possible.
"""
import unicodedata

GENRES = frozenset(('综合', '新闻', '体育', '电影', '剧集', '娱乐', '儿童',
                    '纪录片', '音乐', '宗教', '公共事务'))


def _scope(channel, categories):
    path, seen = [], set()
    identity = channel.get('categoryId')
    while identity:
        if identity in seen or identity not in categories:
            return None
        seen.add(identity)
        item = categories[identity]
        path.insert(0, item['name'])
        identity = item.get('parentId')
    if len(path) >= 3 and path[0] == '国际' and path[2] == '电视':
        path.pop(2)
    # Only a recognized automatic international genre is classification-only.
    # All additional hierarchy, local regions and unknown countries fail closed.
    if channel.get('mergeId'):
        return None
    name = unicodedata.normalize('NFKC', channel['name']).strip().casefold()
    if (len(path) in (2, 3) and path[0] == '国际'
            and path[1] not in ('未识别地区', '其他', '未知', '')):
        if len(path) == 2:
            return ('international-unclassified', path[1], name)
        if path[2] in GENRES:
            return ('international-genre', path[1], name)
    # Exact domestic hierarchy is already the publisher's service boundary.
    # Retained historical IDs must not create an extra card in that same path.
    # Provinces, television/audio categories and all nested regions stay distinct.
    if len(path) >= 2 and path[0] == '中国' and '其他' not in path:
        return ('domestic-exact-path', tuple(path), name)
    return None


def coalesce_classification_variants(channels, categories, *, previous=None,
                                     protected_urls=frozenset()):
    """Return one public identity per compatible exact service, with no IO.

    The oldest previous representative remains authoritative so repeated
    publication and genre-only moves do not churn favorites or EPG IDs.
    """
    groups = {}
    for channel in channels:
        scope = _scope(channel, categories)
        if scope is not None:
            groups.setdefault(scope, []).append(channel)
    previous_ids = {}
    previous_channels = {}
    if previous:
        old_categories = {c['id']: c for c in previous['categories']}
        for channel in previous['channels']:
            scope = _scope(channel, old_categories)
            if scope is not None:
                previous_ids.setdefault(scope, []).append(channel['id'])
                previous_channels.setdefault(scope, []).append(channel)
    replacement, removed = {}, set()
    for scope, members in groups.items():
        if len(members) < 2:
            # Reuse an old ID only when the exact same route proves continuity.
            # A disjoint new source cannot take over a retired service's ID.
            if not previous:
                continue
        if any(c.get('mergeId') or any(r['url'] in protected_urls for r in c['routes'])
               for c in members):
            continue
        if any(len({c.get(field) for c in members}) > 1
               for field in ('epgId', 'regionCode', 'countryCode')):
            continue
        order = previous_ids.get(scope, [])
        winner = min(members, key=lambda c: (
            order.index(c['id']) if c['id'] in order else len(order),
            c.get('sortOrder', 0), c['id']))
        identity = winner['id']
        if previous and order:
            urls = {r['url'] for c in members for r in c['routes']}
            old = next((c for c in previous_channels.get(scope, [])
                        if any(r['url'] in urls for r in c['routes'])
                        and all(c.get(field) == winner.get(field)
                                for field in ('epgId', 'regionCode', 'countryCode'))), None)
            if old is not None:
                identity = old['id']
        merged = {**winner, 'id': identity, 'routes': []}
        category_ids = list(dict.fromkeys(identity for member in members
            for identity in member.get('categoryIds', [member['categoryId']])))
        if len(category_ids) > 1:
            merged['categoryIds'] = category_ids
        seen_routes = set()
        for member in members:
            for route in member['routes']:
                if route['id'] not in seen_routes:
                    merged['routes'].append(route)
                    seen_routes.add(route['id'])
            removed.add(member['id'])
        replacement[winner['id']] = merged
    return [replacement[c['id']] if c['id'] in replacement else c
            for c in channels if c['id'] not in removed or c['id'] in replacement]
