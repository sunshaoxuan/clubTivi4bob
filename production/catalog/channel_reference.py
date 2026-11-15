"""Versioned public broadcaster metadata, refreshed by the source worker."""
import hashlib
import json
import os
import re
import time
import unicodedata
import urllib.request
from pathlib import Path

API = 'https://iptv-org.github.io/api/'
FILENAME = 'channel-reference.json'
TOPICS = {
    'movies': '电影', 'series': '剧集', 'animation': '动漫', 'kids': '少儿',
    'documentary': '纪录片', 'music': '音乐', 'sports': '体育', 'news': '新闻',
    'education': '教育', 'science': '科普', 'travel': '旅行', 'cooking': '美食',
    'culture': '文化', 'entertainment': '娱乐', 'comedy': '喜剧',
    'business': '财经', 'lifestyle': '生活', 'auto': '汽车', 'outdoor': '户外',
    'weather': '天气', 'religious': '宗教', 'shop': '购物', 'general': '综合',
    'legislative': '公共事务', 'classic': '经典', 'family': '家庭',
    'relax': '休闲', 'interactive': '互动', 'public': '公共', 'xxx': '成人',
}


def key(value):
    text = unicodedata.normalize('NFKC', value).casefold().strip()
    text = re.sub(r'\s*\[(?:geo-blocked|not 24/7)\]', '', text)
    text = re.sub(r'\s*\((?:\d{3,4}[pi]|hd|sd|fhd|\d{1,2})\)$', '', text)
    text = re.sub(r'(?:\s+|[-_])(?:hd|sd|fhd|\d{3,4}[pi])$', '', text)
    return re.sub(r'[\s_-]+', '', text)


class Reference:
    def __init__(self, data=None):
        self.countries, self.ids, self.names = {}, {}, {}
        if not data:
            return
        if data.get('schemaVersion') != 1:
            raise ValueError('Unknown channel reference schema')
        self.countries = data['countries']
        for item in data['channels']:
            self.ids[item['id'].casefold()] = item
            for name in [item['name'], *item['aliases']]:
                self.names.setdefault(key(name), {})[item['id']] = item

    def lookup(self, name, epg=None, country=None):
        epg_key = re.sub(r'@.*$', '', (epg or '').casefold())
        exact = self.ids.get(epg_key)
        if exact:
            return exact if not country or exact['country'] == country else None
        name_key = key(name)
        if not country and name_key in {'news', 'cinema', 'movies', 'music', 'fashion', 'tv', 'channel', 'entertainment', 'general'}:
            return None
        candidates = list(self.names.get(name_key, {}).values())
        if country:
            candidates = [c for c in candidates if c['country'] == country]
        # Exact full-name equality is required; fuzzy names remain AI work.
        return candidates[0] if len(candidates) == 1 else None


def load(directory):
    path = Path(directory) / FILENAME
    try:
        return Reference(json.loads(path.read_text(encoding='utf-8')))
    except (OSError, ValueError, KeyError, TypeError):
        return Reference()


def _fetch(resource):
    request = urllib.request.Request(API + resource + '.json', headers={'User-Agent': 'BobTV-Catalog/1.0'})
    with urllib.request.urlopen(request, timeout=25) as response:
        body = response.read(20_000_001)
    if len(body) > 20_000_000:
        raise ValueError('Reference exceeds size limit')
    return json.loads(body)


def refresh(directory, fetcher=_fetch, now=None):
    """Atomic cache replacement; failures retain the last validated reference."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / FILENAME
    now = int(time.time()) if now is None else now
    if target.exists() and now - target.stat().st_mtime < 86400:
        return {'status': 'not-due'}
    try:
        country_rows, channel_rows = fetcher('countries'), fetcher('channels')
        countries = {('GB' if r['code'] == 'UK' else r['code']): r['name'] for r in country_rows
                     if re.fullmatch('[A-Z]{2}', r['code']) and isinstance(r['name'], str)}
        channels = []
        for row in channel_rows:
            country = 'GB' if row['country'] == 'UK' else row['country']
            if row.get('closed') or row.get('replaced_by') or country not in countries:
                continue
            if (not isinstance(row['id'], str) or not isinstance(row['name'], str)
                    or not 1 <= len(row['name']) <= 128):
                raise ValueError('Invalid channel reference')
            channels.append({'id': row['id'], 'name': row['name'], 'country': country,
                             'aliases': [a for a in row['alt_names'] if isinstance(a, str) and len(a) <= 128],
                             'topics': [TOPICS[c] for c in row['categories'] if c in TOPICS]})
        if not 100 <= len(countries) <= 300 or not 1000 <= len(channels) <= 100000:
            raise ValueError('Incomplete channel reference')
        data = {'schemaVersion': 1, 'source': API, 'retrievedAt': now,
                'countries': countries, 'channels': channels}
        body = json.dumps(data, ensure_ascii=False, separators=(',', ':')).encode()
        temporary = target.with_suffix('.tmp')
        temporary.write_bytes(body)
        os.replace(temporary, target)
        return {'status': 'ok', 'channels': len(channels), 'countries': len(countries),
                'sha256': hashlib.sha256(body).hexdigest()}
    except Exception:
        return {'status': 'failed', 'retainedPrevious': target.exists()}
