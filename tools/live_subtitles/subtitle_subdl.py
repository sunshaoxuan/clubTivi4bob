"""IMDb-bound public SubDL discovery; no credentials or translation requests."""
import concurrent.futures
import hashlib
from html.parser import HTMLParser
import io
import json
from pathlib import Path
import re
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen
import zipfile

from subtitle_catalog import LANGUAGES, matches_movie_title, parse_srt, title_norm

LANGUAGE_CODES = {'english':'en', 'chinese_bg_code':'zh-CN', 'big_5_code':'zh-TW',
                  'chinesebgcode':'zh-CN', 'big5code':'zh-TW', 'japanese':'ja', 'french':'fr', 'spanish':'es', 'korean':'ko'}


def read(url):
    p=urlsplit(url)
    if p.scheme!='https' or p.username or p.port not in (None,443):
        raise ValueError('invalid_subdl_resource')
    if p.hostname=='api3.subdl.com':
        allowed=p.path=='/auto'
    elif p.hostname=='subdl.com':
        allowed=bool(re.fullmatch(r'/subtitle/sd[0-9]+/[a-z0-9-]+',p.path))
    elif p.hostname=='dl.subdl.com':
        allowed=bool(re.fullmatch(r'/subtitle/[0-9]+-[0-9]+\.zip',p.path))
    else:allowed=False
    if not allowed:raise ValueError('unreviewed_subdl_resource')
    with urlopen(Request(url,headers={'User-Agent':'Mozilla/5.0 BobTV-Subtitle/1.0', 'Referer':'https://subdl.com/'}),timeout=12) as r:
        if urlsplit(r.url).hostname!=p.hostname:raise ValueError('unreviewed_subdl_redirect')
        raw=r.read(4*1024*1024+1)
    if len(raw)>4*1024*1024:raise ValueError('subtitle_response_limit')
    return raw


class Releases(HTMLParser):
    def __init__(self):
        super().__init__();self.language=None;self.label='';self.capture=False;self.rows=[]
    def handle_starttag(self,tag,attrs):
        a=dict(attrs)
        if 'data-language-name' in a:
            self.language=LANGUAGE_CODES.get(a.get('data-language'));self.label=''
        if tag=='a' and 'data-subtitle-title' in a:
            self.capture=True;self.label=''
        if tag=='a' and 'data-subtitle-download' in a and self.language and self.label:
            url=a.get('href','')
            if re.fullmatch(r'https://dl\.subdl\.com/subtitle/[0-9]+-[0-9]+\.zip',url):
                self.rows.append(dict(language=self.language,label=self.label.strip(),url=url))
    def handle_data(self,data):
        if self.capture:self.label+=data
    def handle_endtag(self,tag):
        if tag=='a':self.capture=False


def unpack(raw):
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        entries=archive.infolist()
        if len(entries)>16 or sum(e.file_size for e in entries)>8*1024*1024:
            raise ValueError('subtitle_archive_limit')
        for e in entries:
            if e.is_dir() or not e.filename.lower().endswith('.srt'):continue
            if e.file_size>2*1024*1024 or e.flag_bits&1:continue
            data=archive.read(e)
            for encoding in ('utf-8-sig','utf-16' if data.startswith((b'\xff\xfe',b'\xfe\xff')) else 'utf-8','gb18030','cp1252'):
                try:
                    normalized=data.decode(encoding).encode('utf-8')
                    return normalized,parse_srt(normalized)
                except (UnicodeError,ValueError):continue
    raise ValueError('usable_srt_required')


def discover(title,year,root,*,imdb_id,max_candidates=3):
    if not isinstance(imdb_id,str) or not re.fullmatch(r'tt[0-9]{7,10}',imdb_id):return []
    root=Path(root);root.mkdir(parents=True,exist_ok=True)
    lookup='https://api3.subdl.com/auto?'+urlencode({'query':imdb_id})
    response=json.loads(read(lookup));rows=response.get('results',[])
    # IMDb lookup must be unambiguous, including the original title and year.
    if len(rows)!=1:return []
    movie=rows[0]
    if (movie.get('type')!='movie' or movie.get('year')!=year
        or title_norm(movie.get('original_name') or movie.get('name',''))!=title_norm(title)):
        return []
    path=movie.get('link','')
    if not re.fullmatch(r'/subtitle/sd[0-9]+/[a-z0-9-]+',path):return []
    page='https://subdl.com'+path
    parser=Releases();parser.feed(read(page).decode('utf-8'))
    selected=[]
    for language in LANGUAGES:
        releases=[r for r in parser.rows if r['language']==language and matches_movie_title(r['label'],title,year)]
        selected.extend(releases[:max_candidates if language=='en' else 2])
    tracks=[]
    def download(row):
        try:
            archive=read(row['url']);data,cues=unpack(archive);digest=hashlib.sha256(data).hexdigest()
            (root/(digest+'.srt')).write_bytes(data)
            return {**row,'cues':cues,'sha256':digest,'archiveSha256':hashlib.sha256(archive).hexdigest()}
        except (OSError,ValueError,UnicodeError,zipfile.BadZipFile):return None
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        tracks=[r for r in pool.map(download,selected) if r]
    results=[]
    for en in [r for r in tracks if r['language']=='en']:
        grid=[(c['start'],c['end']) for c in en['cues']]
        chosen={'en':en}
        for r in tracks:
            if r['language'] not in chosen and [(c['start'],c['end']) for c in r['cues']]==grid:
                chosen[r['language']]=r
        provenance={lang:dict(provider='SubDL',url=r['url'],sha256=r['sha256'],archiveSha256=r['archiveSha256'],cueCount=len(r['cues']),identityLookup=lookup,imdbId=imdb_id,release=r['label']) for lang,r in chosen.items()}
        results.append(dict(page=en['url'],label=en['label'],searchUrl=lookup,
            tracks={lang:r['cues'] for lang,r in chosen.items()},provenance=provenance))
    (root/'subdl-discovery.json').write_text(json.dumps(dict(identityLookup=lookup,movie=movie,offeredLanguages=sorted({r['language'] for r in parser.rows}),downloadedLanguages=sorted({r['language'] for r in tracks}),candidates=results),ensure_ascii=False))
    return results
