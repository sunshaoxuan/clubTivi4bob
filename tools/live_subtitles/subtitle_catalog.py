"""Retrieve existing subtitle files. Never invoke translation/generation actions."""
import hashlib
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


def discover(title, year, root, *, max_candidates=3):
    """Title/year selects candidates only. An acoustic lock is mandatory later."""
    root = Path(root); root.mkdir(parents=True, exist_ok=True)
    search = ORIGIN + '/index.php?' + urlencode({'search': f'{title} {year}'})
    parser = Links(); parser.feed(read(search).decode())
    title_words = norm(title)
    required = set(title_words) | {str(year)}
    matches = [x for x in parser.links if urlsplit(urljoin(ORIGIN, x['url'])).path.startswith('/subs/')
               and x['url'].endswith('.html') and required <= set(norm(x['text']))
               and norm(x['text'])[:len(title_words)] == title_words]
    results = []
    for candidate in matches[:max_candidates]:
        page = urljoin(ORIGIN, candidate['url']); links = Links(); links.feed(read(page).decode())
        tracks, facts = {}, {}
        for language in LANGUAGES:
            link = next((x for x in links.links if x['id'] == 'download_' + language
                         and x['text'].strip() == 'Download' and x['url'].endswith('.srt')), None)
            if link is None:
                continue
            url = urljoin(ORIGIN, link['url'])
            try:
                raw = read(url); cues = parse_srt(raw)
            except (ValueError, OSError, UnicodeError):
                continue
            tracks[language] = cues
            digest = hashlib.sha256(raw).hexdigest()
            (root / (digest + '.srt')).write_bytes(raw)
            facts[language] = dict(url=url, sha256=digest, cueCount=len(cues), provider='Subtitle Cat',
                                   quality='existing provider file; translation quality unreviewed')
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
    (root / 'discovery.json').write_text(json.dumps(results, ensure_ascii=False))
    return results
