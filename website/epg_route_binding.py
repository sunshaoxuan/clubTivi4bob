"""Exact route scopes with legacy-safe public identities. No implicit approvals."""
import hashlib
import re

from epg_ingest import EpgError


def validate_scope(scope, channel):
    if not isinstance(scope, list) or not 1 <= len(scope) <= 100:
        raise EpgError('invalid_epg_route_scope')
    catalogue = {r['id']: hashlib.sha256(r['url'].encode()).hexdigest()
                 for r in channel.get('routes', [])}
    ids = []
    for item in scope:
        if (not isinstance(item, dict) or set(item) != {'routeId', 'urlSha256'}
                or not isinstance(item['routeId'], str)
                or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', item['routeId'])
                or not isinstance(item['urlSha256'], str)
                or not re.fullmatch(r'[a-f0-9]{64}', item['urlSha256'])
                or catalogue.get(item['routeId']) != item['urlSha256']):
            raise EpgError('epg_route_identity_drift')
        ids.append(item['routeId'])
    if len(set(ids)) != len(ids) or ids != sorted(ids):
        raise EpgError('invalid_epg_route_scope')
    return scope


def public_identity(channel, identity_hash, scope):
    binding = {'schemaVersion': 1, 'catalogChannelId': channel['id'],
               'catalogIdentityHash': identity_hash, 'routes': scope}
    material = '\n'.join([channel['id'], identity_hash] +
                         [r['routeId'] + ':' + r['urlSha256'] for r in scope])
    guide_id = 'route-epg-' + hashlib.sha256(material.encode()).hexdigest()
    return {**channel, 'id': guide_id, 'routeBinding': binding}
