"""Conservative IMDb title/year resolution with persistent provenance and backoff."""
import hashlib
import json
from pathlib import Path
import re
import time
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen
from subtitle_catalog import title_norm


def read(url):
    with urlopen(Request(url,headers={'User-Agent':'BobTV-Subtitle/1.0'}),timeout=10) as response:
        if urlsplit(response.url).hostname != 'v3.sg.media-imdb.com':
            raise ValueError('unreviewed_identity_redirect')
        raw=response.read(1024*1024+1)
    if len(raw)>1024*1024:raise ValueError('identity_response_limit')
    return json.loads(raw)


def resolve(programme,root,*,clock=time.time):
    if re.fullmatch(r'tt[0-9]{7,10}',str(programme.get('imdbId',''))):return programme
    title=programme.get('title');year=programme.get('year')
    if not isinstance(title,str) or not 0<len(title)<=200 or not isinstance(year,int):return programme
    key=hashlib.sha256(json.dumps([title_norm(title),year]).encode()).hexdigest()
    folder=Path(root)/'.identity-lookups';folder.mkdir(parents=True,exist_ok=True);path=folder/(key+'.json')
    try:record=json.loads(path.read_text())
    except (OSError,ValueError):record={}
    if record.get('title')!=title or record.get('year')!=year:record={}
    ttl=86400 if record.get('outcome')=='unconfirmed' else 60
    if not record.get('imdbId') and (not record or clock()-record.get('checkedAt',0)>=ttl):
        url='https://v3.sg.media-imdb.com/suggestion/x/'+quote(title.lower(),safe='')+'.json'
        record=dict(title=title,year=year,checkedAt=clock(),lookup=url)
        try:
            rows=read(url).get('d',[])
            ids={r['id'] for r in rows if r.get('qid')=='movie' and r.get('y')==year and
                title_norm(r.get('l',''))==title_norm(title) and re.fullmatch(r'tt[0-9]{7,10}',r.get('id',''))}
            record.update(outcome='verified' if len(ids)==1 else 'unconfirmed',imdbId=next(iter(ids)) if len(ids)==1 else None)
        except (OSError,ValueError,KeyError,TypeError):record.update(outcome='temporarily_unavailable',imdbId=None)
        temporary=path.with_suffix('.tmp');temporary.write_text(json.dumps(record));temporary.replace(path)
    return {**programme,'imdbId':record['imdbId']} if record.get('imdbId') else programme
