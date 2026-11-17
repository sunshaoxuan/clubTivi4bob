"""IMDb-bound existing OpenSubtitles resources from its public Stremio addon."""
import concurrent.futures
import json
from pathlib import Path
import re
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
from subtitle_catalog import matches_movie_title, parse_srt, save_resource, load_resource

# Chinese script cannot be inferred safely from a generic ISO Chinese tag.
CODES = {'eng':'en', 'jpn':'ja', 'fre':'fr', 'spa':'es', 'kor':'ko'}


def read(url):
    p = urlsplit(url)
    allowed = ((p.hostname == 'opensubtitles-v3.strem.io' and
                re.fullmatch(r'/subtitles/movie/tt[0-9]{7,10}\.json', p.path)) or
               (p.hostname == 'subs5.strem.io' and
                re.fullmatch(r'/en/download/subencoding-stremio-utf8/src-api/file/[0-9]+', p.path)))
    if p.scheme != 'https' or p.username or p.port not in (None, 443) or not allowed:
        raise ValueError('unreviewed_opensubtitles_resource')
    with urlopen(Request(url, headers={'User-Agent':'BobTV-Subtitle/1.0'}), timeout=12) as r:
        if urlsplit(r.url).hostname != p.hostname:
            raise ValueError('unreviewed_opensubtitles_redirect')
        raw = r.read(2 * 1024 * 1024 + 1)
    if len(raw) > 2 * 1024 * 1024:
        raise ValueError('subtitle_response_limit')
    return raw


def discover(title, year, root, *, imdb_id, max_candidates=3):
    if not isinstance(imdb_id, str) or not re.fullmatch(r'tt[0-9]{7,10}', imdb_id):
        return []
    root = Path(root); root.mkdir(parents=True, exist_ok=True)
    lookup = f'https://opensubtitles-v3.strem.io/subtitles/movie/{imdb_id}.json'
    rows = json.loads(read(lookup)).get('subtitles', [])
    selected = []
    for code, language in CODES.items():
        admitted = [dict(row, language=language, label=row.get('movieReleaseName','').replace('.', ' '))
                    for row in rows if row.get('lang') == code and
                    row.get('season', 0) == 0 and row.get('episode', 0) == 0 and
                    matches_movie_title(row.get('movieReleaseName','').replace('.', ' '), title, year)]
        selected.extend(admitted[:max_candidates if language == 'en' else 2])
    def download(row):
        try:
            cached = load_resource(root, row['url'], row['language'])
            if cached: return {**row, **cached[0], 'cues':cached[1]}
            raw = read(row['url']); cues = parse_srt(raw)
            record = save_resource(root, row['url'], row['language'], row['label'], raw,
                'OpenSubtitles via Stremio', imdbId=imdb_id, identityLookup=lookup)
            return {**row, **record, 'cues':cues}
        except (OSError, ValueError, UnicodeError):
            return None
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        tracks = [row for row in pool.map(download, selected) if row]
    results = []
    for english in [row for row in tracks if row['language'] == 'en']:
        grid = [(c['start'], c['end']) for c in english['cues']]
        chosen = {'en':english}
        for row in tracks:
            if row['language'] not in chosen and [(c['start'], c['end']) for c in row['cues']] == grid:
                chosen[row['language']] = row
        results.append(dict(page=english['url'], label=english['label'], searchUrl=lookup,
            tracks={lang:row['cues'] for lang,row in chosen.items()},
            provenance={lang:dict(provider='OpenSubtitles via Stremio', url=row['url'],
                sha256=row['sha256'], cueCount=len(row['cues']), imdbId=imdb_id,
                identityLookup=lookup, release=row['label']) for lang,row in chosen.items()}))
    (root/'opensubtitles-discovery.json').write_text(json.dumps(results, ensure_ascii=False))
    return results
