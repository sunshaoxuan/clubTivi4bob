"""IMDb-bound existing OpenSubtitles resources from its public Stremio addon."""
from subtitle_io import pool as download_pool
import json
from pathlib import Path
import re
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
from subtitle_edition import chinese_script, pair_reference
from subtitle_catalog import title_norm, matches_movie_title, parse_srt, save_resource, load_resource

# Generic Chinese tags require inspecting actual characters after download.
CODES = {'eng':'en', 'jpn':'ja', 'fre':'fr', 'spa':'es', 'kor':'ko',
         'chi':'zh', 'zho':'zh', 'zhs':'zh', 'zht':'zh'}
PROVIDER = 'OpenSubtitles via Stremio'

def matches_bound_release(label, title, year):
    if matches_movie_title(label, title, year):
        return True
    expected, words = title_norm(title), title_norm(label)
    if not expected or words[:len(expected)] != expected:
        return False
    suffix = words[len(expected):]
    # The provider lookup is already scoped to the verified IMDb ID. Accept
    # yearless labels only when the next token denotes an edition, not a sequel.
    if any(re.fullmatch(r'(?:18|19|20)[0-9]{2}', word) and word != str(year) for word in suffix):
        return False
    return (not suffix or suffix[0] in {'webrip', 'webdl', 'bluray', 'bdrip', 'dvdrip', 'hdtv'}
            or suffix[:2] in (['blu', 'ray'], ['web', 'rip'], ['web', 'dl']))


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


def discover(title, year, root, *, imdb_id, max_candidates=3, aliases=(), reviewer=None):
    if not isinstance(imdb_id, str) or not re.fullmatch(r'tt[0-9]{7,10}', imdb_id):
        return []
    root = Path(root); root.mkdir(parents=True, exist_ok=True)
    lookup = f'https://opensubtitles-v3.strem.io/subtitles/movie/{imdb_id}.json'
    rows = json.loads(read(lookup)).get('subtitles', [])
    selected = {}
    for code, language in CODES.items():
        admitted = [dict(row, language=language, label=row.get('movieReleaseName','').replace('.', ' '))
                    for row in rows if row.get('lang') == code and
                    row.get('season', 0) == 0 and row.get('episode', 0) == 0 and
                    any(matches_bound_release(row.get('movieReleaseName','').replace('.', ' '), name, year)
                        for name in (title, *aliases))]
        for row in admitted:
            url = row.get('url')
            selected.setdefault((language, url if isinstance(url, str) else None), row)
    if reviewer and not any(language == 'en' for language, _ in selected):
        eligible = [row for row in rows if row.get('lang') == 'eng'
                    and row.get('season',0)==0 and row.get('episode',0)==0
                    and isinstance(row.get('movieReleaseName'),str) and isinstance(row.get('url'),str)][:16]
        approved = reviewer(title, year, imdb_id, [row['movieReleaseName'] for row in eligible])
        for i in sorted(approved):
            row = eligible[i]
            selected.setdefault(('en',row['url']),
                dict(row,language='en',label=row['movieReleaseName'].replace('.',' '),aiReviewed=True))
    failures=[]
    def download(row):
        try:
            cached = load_resource(root, row['url'], row['language'])
            if cached:
                record, cues = cached
            else:
                raw = read(row['url'])
                cues = parse_srt(raw)
                record = save_resource(root, row['url'], row['language'], row['label'], raw,
                    PROVIDER, imdbId=imdb_id, identityLookup=lookup)
            return {**row, **record, 'language': chinese_script(cues, row['language']),
                    'declaredLanguage': row['language'], 'cues': cues, 'cached': cached is not None}
        except (OSError, ValueError, UnicodeError, TypeError, AttributeError, KeyError) as error:
            failures.append(dict(url=row.get('url'),language=row['language'],errorType=type(error).__name__,httpStatus=getattr(error,'code',None)))
            return None
    with download_pool() as pool:
        tracks = [row for row in pool.map(download, selected.values()) if row]
    def facts(row):
        return dict(provider=PROVIDER, url=row['url'], sha256=row['sha256'],
            cueCount=len(row['cues']), imdbId=imdb_id, identityLookup=lookup,
            release=row['label'], declaredLanguage=row['declaredLanguage'],
            aiIdentityReviewed=row.get('aiReviewed') is True)
    translations = [(row['language'], row['cues'], facts(row)) for row in tracks
                    if row['language'] not in (None, 'en')]
    results = []
    for english in [row for row in tracks if row['language'] == 'en']:
        results.extend(pair_reference(dict(page=english['url'], label=english['label'], searchUrl=lookup),
                                     english['cues'], facts(english), translations))
    (root/'opensubtitles-search-audit.json').write_text(json.dumps(dict(
        offeredRows=len(rows), selectedRows=len(selected), parsedRows=len(tracks),
        downloadedRows=sum(not row['cached'] for row in tracks),
        cacheHits=sum(row['cached'] for row in tracks),
        unidentifiedLanguageRows=sum(row['language'] is None for row in tracks),
        downloadedLanguages=sorted({row['language'] for row in tracks if row['language']}),
        allMatchingRowsAttempted=True, failures=failures)))
    (root/'opensubtitles-discovery.json').write_text(json.dumps(results, ensure_ascii=False))
    return results
