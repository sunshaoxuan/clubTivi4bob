"""Canonical Simplified Chinese country labels, shared with the desktop client."""
import copy
import json
import re
from pathlib import Path

_DATA = json.loads(Path(__file__).with_suffix('.json').read_text(encoding='utf-8'))
ALIASES = _DATA['aliases']


def normalize_country_name(name):
    cleaned = re.sub(r'\s+', ' ', name.strip())
    return ALIASES.get(cleaned.lower(), cleaned)


def normalize_group(group):
    parts = group.split(' / ')
    if len(parts) >= 2 and parts[0] == '国际':
        parts[1] = normalize_country_name(parts[1])
    return ' / '.join(parts)


def normalize_catalog_countries(payload):
    """Merge equivalent country subtrees while preserving channels and routes.

    Caller validates the tree first. Existing Chinese category IDs win ties,
    so repeated publication is idempotent and existing references stay stable.
    """
    result = copy.deepcopy(payload)
    lookup = {item['id']: item for item in result['categories']}
    roots = {item['id'] for item in lookup.values()
             if item['parentId'] is None and item['name'] == '国际'}
    mapped = {}
    output = {}
    scopes = {}

    def visit(identity):
        if identity in mapped:
            return mapped[identity]
        item = lookup[identity]
        parent = item['parentId']
        canonical_parent = visit(parent) if parent is not None else None
        name = normalize_country_name(item['name']) if parent in roots else item['name']
        inside = parent in roots or (parent is not None and scopes.get(parent, False))
        scopes[identity] = inside
        key = (canonical_parent, name)
        if inside and key in equivalents:
            mapped[identity] = equivalents[key]
        else:
            output[identity] = {**item, 'name': name, 'parentId': canonical_parent}
            mapped[identity] = identity
            if inside:
                equivalents[key] = identity
        return mapped[identity]

    equivalents = {}
    # Prefer already-canonical country nodes, independent of input ordering.
    def priority(identity):
        depth = 0
        current = identity
        translated = False
        while current is not None:
            item = lookup[current]
            if item['parentId'] in roots:
                translated = item['name'] != normalize_country_name(item['name'])
            current = item['parentId']
            depth += 1
        return (translated, depth)

    ordered = sorted(lookup, key=priority)
    for identity in ordered:
        visit(identity)
    result['categories'] = list(output.values())
    for channel in result['channels']:
        channel['categoryId'] = mapped[channel['categoryId']]
        if 'categoryIds' in channel:
            channel['categoryIds'] = list(dict.fromkeys(mapped[key] for key in channel['categoryIds']))
    return result
