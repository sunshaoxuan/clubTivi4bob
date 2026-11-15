"""Broadcast-edition geography, distinct from operator and content origin.

Only reviewed provider service bindings can propose a country change. Playlist
groups, language, CDN location, EPG suffixes and operator domicile are hints for
review, never authority for this decision. This module performs no IO or writes.
"""
import hashlib
import re
import json
from pathlib import Path
from urllib.parse import urlsplit


POLICY_VERSION = 'broadcast-edition-market-v1'
_RAKUTEN_PATH = re.compile(
    r'/v1/(?:master|manifest)/[a-f0-9]{40}/production-LiveChannel-(\d+)/'
    r'(?:[a-f0-9-]{36}/)?(?:master|[0-9]+)\.m3u8')


def load_matching_bindings(path=None):
    """Enable only reviewed services approved for the persistent matcher."""
    path = Path(path) if path else Path(__file__).with_name('broadcast_market_bindings.json')
    value = json.loads(path.read_text())
    if value.get('schemaVersion') != 1 or value.get('policyVersion') != POLICY_VERSION:
        raise ValueError('invalid_broadcast_market_policy')
    return [b for b in value['bindings'] if b.get('matchingEnabled') is True]


def provider_service(url):
    """Extract identity only in the reviewed publisher's URL namespace.

    AWS hostnames, similarly spelled domains and country-like URL substrings
    cannot bind a feed. Query strings and session UUIDs do not choose a market.
    """
    if not isinstance(url, str):
        return None
    try:
        p = urlsplit(url)
        if (p.scheme != 'https' or p.username or p.password or p.fragment
                or p.port not in (None, 443)):
            return None
    except ValueError:
        return None
    host = (p.hostname or '').lower()
    if not host.endswith('.fast.rakuten.tv'):
        return None
    match = _RAKUTEN_PATH.fullmatch(p.path)
    if not match:
        return None
    return ('rakuten-tv', host, match[1])


def resolve_market(channel, bindings):
    """Resolve all active routes to one reviewed edition, or abstain.

    Bindings are administrator-reviewed facts, not playlist/AI-supplied data.
    Each binding includes provider, host, serviceId, market, evidenceUrls.
    No channel name, existing category or source registration field participates.
    """
    reviewed = {}
    for binding in bindings:
        key = (binding['provider'], binding['host'], str(binding['serviceId']))
        if (not re.fullmatch('[A-Z]{2}', binding['market'])
                or not binding.get('evidenceUrls')):
            raise ValueError('invalid_broadcast_market_binding')
        reviewed.setdefault(key, []).append(binding)
    routes = channel.get('routes') or []
    if not routes:
        return {'status': 'needs_review', 'reason': 'no_routes', 'market': None}
    matches = []
    for route in routes:
        key = provider_service(route.get('url'))
        facts = reviewed.get(key, [])
        if not facts:
            return {'status': 'needs_review', 'reason': 'unbound_route', 'market': None}
        markets = {fact['market'] for fact in facts}
        if len(markets) != 1:
            return {'status': 'needs_review', 'reason': 'conflicting_binding', 'market': None}
        matches.extend(facts)
    markets = {fact['market'] for fact in matches}
    if len(markets) != 1:
        return {'status': 'needs_review', 'reason': 'mixed_feed_markets', 'market': None}
    return {'status': 'verified_edition', 'reason': 'reviewed_provider_service',
            'market': next(iter(markets)),
            'evidenceUrls': sorted({u for fact in matches for u in fact['evidenceUrls']})}


def category_path(channel, categories):
    path, seen = [], set()
    identity = channel.get('categoryId')
    while identity:
        if identity in seen or identity not in categories:
            raise ValueError('invalid_market_category_tree')
        seen.add(identity)
        item = categories[identity]
        path.insert(0, item['name'])
        identity = item.get('parentId')
    return path


def review_channel(channel, categories, bindings, country_names, *, protected=False):
    """Return an exact, non-mutating proposal for category and metadata together."""
    result = resolve_market(channel, bindings)
    path = category_path(channel, categories)
    market = result['market']
    base = {'channelId': channel['id'], 'name': channel['name'],
            'policyVersion': POLICY_VERSION, 'oldCountryCode': channel.get('countryCode'),
            'oldPath': path, 'protected': protected, **result}
    if not market:
        return base
    label = country_names.get(market.lower())
    if not label or len(path) < 2 or path[0] != '国际':
        return {**base, 'status': 'needs_review', 'reason': 'unsupported_existing_hierarchy'}
    proposed = ['国际', label, *path[2:]]
    changed = channel.get('countryCode') != market or path != proposed
    base.update(proposedCountryCode=market, proposedPath=proposed,
                routeSha256=sorted(hashlib.sha256(r['url'].encode()).hexdigest()
                                   for r in channel['routes']),
                expectedIdentity={k: channel.get(k) for k in
                                  ('id', 'name', 'epgId', 'countryCode', 'regionCode')})
    return {**base, 'status': ('protected_review' if protected and changed else
                              'proposed_correction' if changed else 'consistent')}
