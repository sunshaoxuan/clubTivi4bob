"""Retrieve existing subtitle files. Never invoke translation/generation actions."""
import hashlib
from subtitle_io import pool as download_pool
import html
from html.parser import HTMLParser
import json
from pathlib import Path
import re
from urllib.parse import urlencode, urljoin, urlsplit, quote
from urllib.request import Request, urlopen

LANGUAGES = ('en', 'zh-CN', 'zh-TW', 'ja', 'fr', 'es', 'ko')
ORIGIN = 'https://www.subtitlecat.com'


def read(url):
    parts = urlsplit(url)
    if parts.scheme != 'https' or parts.hostname != 'www.subtitlecat.com' or parts.username:
        raise ValueError('unreviewed_subtitle_host')
    url = quote(url, safe=':/?&=%[]')
    with urlopen(Request(url, headers={'User-Agent': 'Mozilla/5.0 BobTV-Subtitle/1.0'}), timeout=15) as response:
        if urlsplit(response.geturl()).hostname != 'www.subtitlecat.com':
            raise ValueError('unreviewed_subtitle_redirect')
        raw = response.read(2 * 1024 * 1024 + 1)
    if len(raw) > 2 * 1024 * 1024:
        raise ValueError('subtitle_response_limit')
    return raw


class Links(HTMLParser):
    def __init__(self):
        super().__init__(); self.links = []; self.active = None

    def handle_starttag(self, tag, attrs):
        if tag == 'a':
            attributes = dict(attrs)
            self.active = dict(url=attributes.get('href', ''), id=attributes.get('id', ''), text='')

    def handle_data(self, data):
        if self.active is not None:
            self.active['text'] += data

    def handle_endtag(self, tag):
        if tag == 'a' and self.active is not None:
            self.links.append(self.active); self.active = None


def norm(text):
    return re.findall(r"[a-z]+(?:'[a-z]+)?|[0-9]+", html.unescape(text).lower())


def title_norm(text):
    # Release labels commonly omit possessive punctuation. Keep every title
    # word and the exact year while treating Clancy's / Clancys equally.
    return norm(html.unescape(text).replace("'", '').replace('\u2019', ''))


def matches_movie_title(label, title, year):
    """Match the complete title before its release year, never a prefix film."""
    expected = title_norm(title)
    words = title_norm(label)
    return bool(expected and words[:len(expected)] == expected
                and words[len(expected):len(expected)+1] == [str(year)])


def seconds(value):
    h, m, s = value.replace(',', '.').split(':')
    return int(h) * 3600 + int(m) * 60 + float(s)


def parse_srt(raw):
    text = raw.decode('utf-8-sig').replace('\r\n', '\n')
    cues = []
    for block in re.split(r'\n\s*\n', text.strip()):
        match = re.search(r'(\d{1,2}:\d{2}:\d{2}[,.]\d{3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[,.]\d{3})[^\n]*\n(.*)', block, re.S)
        if not match:
            continue
        start, end = seconds(match[1]), seconds(match[2])
        caption = html.unescape(re.sub(r'<[^>]+>', '', match[3])).strip()
        if not (0 <= start < end <= 12 * 3600 and caption and len(caption) <= 8192):
            raise ValueError('invalid_subtitle_cue')
        cues.append(dict(index=len(cues) + 1, start=start, end=end, text=caption))
    if not 3 <= len(cues) <= 20000:
        raise ValueError('invalid_subtitle_count')
    return cues


def resource_path(root, url, language):
    key=hashlib.sha256(json.dumps([url,language],separators=(',',':')).encode()).hexdigest()
    return Path(root)/('subtitle-resource-'+key+'.json')


def save_resource(root, url, language, label, raw, provider, **facts):
    cues=parse_srt(raw);digest=hashlib.sha256(raw).hexdigest();root=Path(root)
    (root/(digest+'.srt')).write_bytes(raw)
    record=dict(provider=provider,url=url,language=language,label=label,
                sha256=digest,bytes=len(raw),cueCount=len(cues),**facts)
    resource_path(root,url,language).write_text(json.dumps(record,ensure_ascii=False))
    return record


def load_resource(root, url, language):
    try:
        record=json.loads(resource_path(root,url,language).read_text())
        digest=record['sha256']
        if record['url']!=url or record['language']!=language or not re.fullmatch(r'[0-9a-f]{64}',digest):return None
        raw=(Path(root)/(digest+'.srt')).read_bytes()
        if len(raw)!=record['bytes'] or len(raw)>2*1024*1024 or hashlib.sha256(raw).hexdigest()!=digest:return None
        return record,parse_srt(raw)
    except (OSError,ValueError,KeyError,UnicodeError):return None


def _discover_subtitlecat(title, year, root, *, max_candidates=3, requested_language='en'):
    """Title/year selects candidates only. An acoustic lock is mandatory later."""
    root = Path(root); root.mkdir(parents=True, exist_ok=True)
    search = ORIGIN + '/index.php?' + urlencode({'search': f'{title} {year}'})
    search_html = read(search).decode()
    parser = Links(); parser.feed(search_html)
    english_originals = set()
    failures = []
    for row in re.findall(r'<tr[^>]*>(.*?)</tr>', search_html, re.S):
        row_parser = Links(); row_parser.feed(row)
        if '(translated from English)' in html.unescape(re.sub(r'<[^>]*>', '', row)):
            english_originals.update(link['url'] for link in row_parser.links)
    matches = [x for x in parser.links if urlsplit(urljoin(ORIGIN, x['url'])).path.startswith('/subs/')
               and x['url'].endswith('.html') and matches_movie_title(x['text'], title, year)]
    # Inspect multiple editions before choosing files. A missing requested
    # language on the first result does not establish provider-wide absence.
    pages = []
    with download_pool() as pool:
        futures = [(candidate, pool.submit(read, urljoin(ORIGIN, candidate['url']))) for candidate in matches]
        for candidate, future in futures:
            try:
                detail = future.result().decode(); links = Links(); links.feed(detail)
            except (OSError, ValueError, UnicodeError) as error:
                failures.append(dict(url=urljoin(ORIGIN,candidate['url']),errorType=type(error).__name__,httpStatus=getattr(error,'code',None)))
                continue
            offered = {x['id'].removeprefix('download_') for x in links.links if x['text'].strip() == 'Download'}
            priority = (requested_language not in offered,
                        not ('en' in offered or candidate['url'] in english_originals),
                        -len(offered & set(LANGUAGES)))
            pages.append((priority, candidate, detail, links))
    results = []
    for _, candidate, detail, links in sorted(pages, key=lambda x:x[0]):
        page = urljoin(ORIGIN, candidate['url'])
        tracks, facts = {}, {}
        for language in LANGUAGES:
            link = next((x for x in links.links if x['id'] == 'download_' + language
                         and x['text'].strip() == 'Download' and x['url'].endswith('.srt')), None)
            if link is None:
                continue
            url = urljoin(ORIGIN, link['url'])
            try:
                cached = load_resource(root,url,language)
                raw = (root/(cached[0]['sha256']+'.srt')).read_bytes() if cached else read(url)
                cues = parse_srt(raw)
            except (ValueError, OSError, UnicodeError) as error:
                failures.append(dict(url=url,language=language,errorType=type(error).__name__,httpStatus=getattr(error,'code',None)))
                continue
            tracks[language] = cues
            digest = hashlib.sha256(raw).hexdigest()
            save_resource(root,url,language,candidate['text'],raw,'Subtitle Cat')
            facts[language] = dict(url=url, sha256=digest, cueCount=len(cues), provider='Subtitle Cat',
                                   quality='existing provider file; translation quality unreviewed')
        if 'en' not in tracks and tracks and candidate['url'] in english_originals:
            # The site publishes the existing English cue text separately from
            # its downloadable language files. Reuse only the exact same cue
            # grid/count from this page; no generated English or translation.
            marker = '<h3>Original subtitles</h3>'
            section = detail.split(marker, 1)[1].split('</div>', 1)[0] if marker in detail else ''
            original = [html.unescape(re.sub(r'<[^>]+>', '', line)).strip()
                        for line in re.findall(r'<p dir="auto">(.*?)</p>', section, re.S)]
            grid_language = next(iter(tracks))
            grid = tracks[grid_language]
            if len(original) == len(grid) and all(0 < len(text) <= 8192 for text in original):
                tracks['en'] = [{**cue, 'text': text} for cue, text in zip(grid, original)]
                facts['en'] = dict(url=page, cueCount=len(original), provider='Subtitle Cat',
                    source='published English original with exact same-source cue grid',
                    clockGridLanguage=grid_language, clockGridSha256=facts[grid_language]['sha256'],
                    sha256=hashlib.sha256(json.dumps(original).encode()).hexdigest())
        if 'en' not in tracks:
            continue
        reference_grid = [(x['start'], x['end']) for x in tracks['en']]
        rejected = []
        for language in list(tracks):
            # Matching cue times are required before transferring English calibration.
            if [(x['start'], x['end']) for x in tracks[language]] != reference_grid:
                del tracks[language]; rejected.append(language)
        result = dict(page=page, label=candidate['text'], tracks=tracks, provenance=facts,
                      rejectedClockGridLanguages=rejected, searchUrl=search)
        results.append(result)
        # Keep a bounded candidate set; a failed acoustic match tries the next file.
    (root/'subtitlecat-search-audit.json').write_text(json.dumps(dict(matchedEditions=len(matches),detailsRead=len(pages),allMatchingRowsAttempted=True,failures=failures)))
    (root / 'discovery.json').write_text(json.dumps(results, ensure_ascii=False))
    return results


def discover(title, year, root, *, max_candidates=3, requested_language='en', imdb_id=None):
    """Independent provider failures must not prevent the next verified source."""
    root=Path(root);root.mkdir(parents=True,exist_ok=True)
    results=[];errors=[];last_error=None
    if imdb_id:
        try:
            from subtitle_stremio import discover as stremio_discover
            results.extend(stremio_discover(title, year, root, imdb_id=imdb_id, max_candidates=max_candidates))
        except Exception as error:
            errors.append(dict(provider='OpenSubtitles via Stremio',error=type(error).__name__,httpStatus=getattr(error,'code',None)))
            last_error=error
    try:
        results.extend(_discover_subtitlecat(title,year,root,max_candidates=max_candidates,requested_language=requested_language))
    except Exception as error:
        errors.append(dict(provider='Subtitle Cat',error=type(error).__name__,httpStatus=getattr(error,'code',None)))
        last_error=error
    if imdb_id and not set(LANGUAGES) <= {language for c in results for language in c['tracks']}:
        try:
            from subtitle_subdl import discover as subdl_discover
            results.extend(subdl_discover(title,year,root,imdb_id=imdb_id,max_candidates=max_candidates))
        except Exception as error:
            errors.append(dict(provider='SubDL',error=type(error).__name__,httpStatus=getattr(error,'code',None)))
            last_error=error
    for name,provider in [('subtitlecat-search-audit.json','Subtitle Cat'),('opensubtitles-search-audit.json','OpenSubtitles via Stremio'),('subdl-discovery.json','SubDL')]:
        if (root/name).exists():
            report=json.loads((root/name).read_text())
            errors.extend(dict(provider=provider,**failure) for failure in report.get('failures',[]))
    (root/'provider-errors.json').write_text(json.dumps(errors))
    (root/'discovery.json').write_text(json.dumps(results,ensure_ascii=False))
    if not results and last_error is not None:raise last_error
    return results
