"""IMDb-bound existing OpenSubtitles resources from its public Stremio addon."""
from subtitle_io import pool as download_pool
import json
from pathlib import Path
import re
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
from subtitle_edition import chinese_script, timing_evidence
from subtitle_catalog import title_norm, matches_movie_title, parse_srt, save_resource, load_resource

# Generic Chinese tags require inspecting actual characters after download.
CODES = {'eng':'en', 'jpn':'ja', 'fre':'fr', 'spa':'es', 'kor':'ko', 'chi':'zh', 'zho':'zh'}


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
                    (matches_movie_title(row.get('movieReleaseName','').replace('.', ' '), title, year) or title_norm(row.get('movieReleaseName',''))==title_norm(title))]
        selected.extend(admitted)
    failures=[]
    def download(row):
        try:
            cached = load_resource(root, row['url'], row['language'])
            if cached:
                actual=chinese_script(cached[1],row['language'])
                return {**row,**cached[0],'language':actual,'cues':cached[1]} if actual else None
            raw = read(row['url']); cues = parse_srt(raw)
            record = save_resource(root, row['url'], row['language'], row['label'], raw,
                'OpenSubtitles via Stremio', imdbId=imdb_id, identityLookup=lookup)
            actual=chinese_script(cues,row['language'])
            return {**row,**record,'language':actual,'cues':cues} if actual else None
        except (OSError, ValueError, UnicodeError) as error:
            failures.append(dict(url=row.get('url'),language=row['language'],errorType=type(error).__name__,httpStatus=getattr(error,'code',None)))
            return None
    with download_pool() as pool:
        tracks = [row for row in pool.map(download, selected) if row]
    results = []
    for english in [row for row in tracks if row['language'] == 'en']:
        facts=lambda row:dict(provider='OpenSubtitles via Stremio',imdbId=imdb_id,release=row['label'])
        chosen = {'en':english}
        for row in tracks:
            if row['language'] not in chosen and timing_evidence(english['cues'],row['cues'],facts(english),facts(row)):
                chosen[row['language']] = row
        results.append(dict(page=english['url'], label=english['label'], searchUrl=lookup,
            tracks={lang:row['cues'] for lang,row in chosen.items()},
            provenance={lang:dict(provider='OpenSubtitles via Stremio', url=row['url'],
                sha256=row['sha256'], cueCount=len(row['cues']), imdbId=imdb_id,
                identityLookup=lookup, release=row['label'],timingEvidence=timing_evidence(english['cues'],row['cues'],facts(english),facts(row))) for lang,row in chosen.items()}))
    (root/'opensubtitles-search-audit.json').write_text(json.dumps(dict(offeredRows=len(rows),selectedRows=len(selected),downloadedRows=len(tracks),allMatchingRowsAttempted=True,failures=failures)))
    (root/'opensubtitles-discovery.json').write_text(json.dumps(results, ensure_ascii=False))
    return results
