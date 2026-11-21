"""IMDb-bound public SubDL discovery; no credentials or translation requests."""
from subtitle_io import pool as download_pool
import hashlib
from html.parser import HTMLParser
import io
import json
from pathlib import Path
import re
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen
import zipfile

from subtitle_edition import chinese_script, pair_reference
from subtitle_catalog import LANGUAGES, matches_movie_title, parse_srt, title_norm, save_resource, load_resource

LANGUAGE_CODES = {'english':'en', 'chinese_bg_code':'zh-CN', 'big_5_code':'zh-TW',
                  'chinesebgcode':'zh-CN', 'big5code':'zh-TW', 'japanese':'ja', 'french':'fr', 'spanish':'es', 'korean':'ko'}
PROVIDER = 'SubDL'


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


def discover(title,year,root,*,imdb_id,max_candidates=3,aliases=()):
    if not isinstance(imdb_id,str) or not re.fullmatch(r'tt[0-9]{7,10}',imdb_id):return []
    root=Path(root);root.mkdir(parents=True,exist_ok=True)
    lookup='https://api3.subdl.com/auto?'+urlencode({'query':imdb_id})
    response=json.loads(read(lookup));rows=response.get('results',[])
    audit_path = root/'subdl-discovery.json'

    def record_identity_failure(reason):
        audit_path.write_text(json.dumps(dict(identityLookup=lookup, identityRows=len(rows),
            reason=reason, offeredRows=0, selectedRows=0, parsedRows=0, failures=[])))
        return []

    # IMDb lookup must be unambiguous, including the original title and year.
    if not rows:return record_identity_failure('imdb_not_listed')
    if len(rows)!=1:return record_identity_failure('ambiguous_imdb_result')
    movie=rows[0]
    if (movie.get('type')!='movie' or movie.get('year')!=year
        or title_norm(movie.get('original_name') or movie.get('name','')) not in
        [title_norm(name) for name in (title,*aliases)]):
        return record_identity_failure('title_year_or_type_mismatch')
    path=movie.get('link','')
    if not re.fullmatch(r'/subtitle/sd[0-9]+/[a-z0-9-]+',path):
        return record_identity_failure('unsupported_provider_detail_url')
    page='https://subdl.com'+path
    parser=Releases();parser.feed(read(page).decode('utf-8'))
    selected={}
    for language in LANGUAGES:
        releases=[r for r in parser.rows if r['language']==language and any(
            matches_movie_title(r['label'],name,year) or title_norm(r['label'])==title_norm(name)
            for name in (title,*aliases))]
        for row in releases:
            selected.setdefault((language,row['url']),row)
    tracks=[]
    failures=[]
    def download(row):
        try:
            cached=load_resource(root,row['url'],row['language'])
            if cached:
                record, cues = cached
            else:
                archive=read(row['url']);data,cues=unpack(archive)
                record=save_resource(root,row['url'],row['language'],row['label'],data,PROVIDER,
                    archiveSha256=hashlib.sha256(archive).hexdigest(),imdbId=imdb_id,identityLookup=lookup)
            return {**row, **record, 'language': chinese_script(cues, row['language']),
                    'declaredLanguage': row['language'], 'cues': cues, 'cached': cached is not None}
        except (OSError,ValueError,UnicodeError,zipfile.BadZipFile) as error:
            failures.append(dict(url=row.get('url'),language=row['language'],errorType=type(error).__name__,httpStatus=getattr(error,'code',None)))
            return None
    with download_pool() as pool:
        tracks=[r for r in pool.map(download,selected.values()) if r]
    def facts(row):
        return dict(provider=PROVIDER, url=row['url'], sha256=row['sha256'],
            archiveSha256=row.get('archiveSha256'), cueCount=len(row['cues']),
            identityLookup=lookup, imdbId=imdb_id, release=row['label'],
            declaredLanguage=row['declaredLanguage'])

    translations = [(row['language'], row['cues'], facts(row)) for row in tracks
                    if row['language'] not in (None, 'en')]
    results=[]
    for english in [row for row in tracks if row['language'] == 'en']:
        results.extend(pair_reference(dict(page=english['url'], label=english['label'], searchUrl=lookup),
                                     english['cues'], facts(english), translations))
    audit_path.write_text(json.dumps(dict(
        identityLookup=lookup, movie=movie, offeredLanguages=sorted({r['language'] for r in parser.rows}),
        offeredRows=len(parser.rows), selectedRows=len(selected), parsedRows=len(tracks),
        downloadedRows=sum(not row['cached'] for row in tracks),
        cacheHits=sum(row['cached'] for row in tracks), allMatchingRowsAttempted=True, failures=failures,
        downloadedLanguages=sorted({row['language'] for row in tracks if row['language']}), candidates=results),
        ensure_ascii=False))
    return results
