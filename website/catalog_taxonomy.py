"""Publication taxonomy: unknown geography is global; radio has its own branch."""
import copy
import hashlib
from urllib.parse import urlsplit
from country_names import _DATA

AUDIO_SUFFIXES = ('.aac', '.mp3', '.m4a', '.ogg', '.opus', '.flac')


def classified_path(path, channel):
    if path[:2] == ['中国', '其他']:
        return ['其他', '待识别', *path[2:]]
    if path[0] == '其他':
        return path
    audio = bool(channel.get('routes')) and all(
        urlsplit(route['url']).path.lower().endswith(AUDIO_SUFFIXES)
        for route in channel['routes'])
    if path[0] == '广播':
        code = (channel.get('countryCode') or '').lower()
        country = _DATA['names'].get(code)
        if code == 'cn':
            return ['中国', '广播', *path[1:]]
        if country:
            return ['国际', country, '广播', *path[1:]]
        return ['其他', '广播', '待识别', *path[1:]]
    if path[0] == '国际' and len(path) >= 2:
        if path[1] in ('未识别地区', '其他', '未知', ''):
            return ['其他', '待识别', *path[2:]]
        tail = path[2:]
        if tail and tail[0] in ('电视', '广播'):
            return path
        if audio:
            return [*path[:2], '广播']
        return [*path[:2], '电视', *(tail or ['综合'])]
    return path


def normalize_catalog_taxonomy(payload):
    result = copy.deepcopy(payload)
    old = {item['id']: item for item in payload['categories']}
    paths = {}

    def path_for(identity):
        if identity not in paths:
            item = old[identity]
            paths[identity] = (path_for(item['parentId']) if item['parentId'] else []) + [item['name']]
        return paths[identity]

    by_path = {tuple(path_for(key)): item for key, item in old.items()}
    used = {}

    def category_for(path):
        parent = None
        for depth in range(1, len(path) + 1):
            key = tuple(path[:depth])
            item = by_path.get(key)
            if item is None:
                identity = 'category-' + hashlib.sha256(' / '.join(key).encode()).hexdigest()[:24]
                item = dict(id=identity, parentId=parent, name=key[-1], sortOrder=10)
                by_path[key] = item
            used[item['id']] = {**item, 'parentId': parent}
            parent = item['id']
        return parent

    for channel in result['channels']:
        original = channel['categoryId']
        primary = category_for(classified_path(path_for(original), channel))
        if 'categoryIds' in channel:
            channel['categoryIds'] = list(dict.fromkeys(category_for(
                classified_path(path_for(key), channel)) for key in channel['categoryIds']))
        channel['categoryId'] = primary
    result['categories'] = list(used.values())
    return result


def apply_channel_paths(payload, changes):
    """Replace only reviewed category references, retaining all public identities."""
    result = copy.deepcopy(payload)
    categories = {item['id']: item for item in result['categories']}
    paths = {}
    def path_for(identity):
        item = categories[identity]
        return (path_for(item['parentId']) if item['parentId'] else []) + [item['name']]
    for identity in categories:
        paths[tuple(path_for(identity))] = identity
    for channel in result['channels']:
        path = changes.get(channel['id'])
        if not path:
            continue
        parent = None
        for depth in range(1, len(path) + 1):
            key = tuple(path[:depth])
            identity = paths.get(key)
            if identity is None:
                identity = 'category-' + hashlib.sha256(' / '.join(key).encode()).hexdigest()[:24]
                categories[identity] = dict(id=identity, parentId=parent, name=key[-1], sortOrder=10)
                paths[key] = identity
            parent = identity
        channel['categoryId'] = parent
        channel.pop('categoryIds', None)
    result['categories'] = list(categories.values())
    return normalize_catalog_taxonomy(result)
