#!/usr/bin/env python3
"""Check that generated HLS windows move and their TS segments can be fetched."""
import argparse
import datetime as dt
import json
from pathlib import Path
import re
import subprocess
import time
from urllib.parse import urljoin, urlsplit
import urllib.request


USE_CURL = False
TRANSPORT_BASE = None


def read(url, limit):
    if TRANSPORT_BASE and urlsplit(url).hostname=='bobtv.briconbric.com':
        parsed=urlsplit(url)
        url=TRANSPORT_BASE.rstrip('/')+parsed.path+('?' + parsed.query if parsed.query else '')
    if USE_CURL:
        data=subprocess.check_output(['curl','--fail','--silent','--show-error',
            '--max-time','15','--max-filesize',str(limit),url],timeout=20)
    else:
        with urllib.request.urlopen(url,timeout=15) as response:
            data=response.read(limit+1)
    if len(data)>limit:raise ValueError('Response is too large')
    return data


def text(url):
    return read(url,8*1024*1024).decode('utf-8')


def snapshot(url):
    value=text(url)
    if '#EXT-X-STREAM-INF:' in value:
        variant=next(line.strip() for line in value.splitlines() if line.strip() and not line.startswith('#'))
        url=urljoin(url,variant);value=text(url)
    match=re.search(r'^#EXT-X-MEDIA-SEQUENCE:(\d+)\s*$',value,re.M)
    segments=[line.strip() for line in value.splitlines() if line.strip() and not line.startswith('#')]
    if not value.startswith('#EXTM3U') or not match or not segments:
        raise ValueError('Expected a media playlist: '+url)
    if '#EXT-X-ENDLIST' in value or '#EXT-X-PLAYLIST-TYPE:VOD' in value:
        raise ValueError('Playlist ended or is VOD: '+url)
    data=read(urljoin(url,segments[-1]),4*1024*1024)
    prefix=data[:188*3]
    if len(prefix)<188*2 or prefix[0]!=0x47 or prefix[188]!=0x47:
        raise ValueError('Expected an MPEG-TS segment')
    return {'sequence':int(match[1]),'segments':segments,'endList':False,'segmentBytesChecked':len(prefix)}


def main():
    global USE_CURL, TRANSPORT_BASE
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package_url')
    parser.add_argument('--wait',type=float,default=7)
    parser.add_argument('--output',type=Path)
    parser.add_argument('--curl',action='store_true',help='Use curl for public CDN requests')
    parser.add_argument('--transport-base',help='Read canonical BobTV resources through this mirror base URL')
    args=parser.parse_args()
    USE_CURL=args.curl
    TRANSPORT_BASE=args.transport_base
    if not 4<=args.wait<=30:parser.error('--wait must be between 4 and 30 seconds')
    package=json.loads(text(args.package_url))
    urls={channel['id']:channel['routes'][0]['url'] for channel in package['channels']}
    if not urls or any(not url.endswith('.m3u8') for url in urls.values()):raise ValueError('Expected HLS-only live package')
    first={key:snapshot(url) for key,url in urls.items()}
    time.sleep(args.wait)
    second={key:snapshot(url) for key,url in urls.items()}
    for key in urls:
        if second[key]['sequence']<=first[key]['sequence']:raise ValueError('Media sequence stopped: '+key)
        if second[key]['segments']==first[key]['segments']:raise ValueError('Window stopped: '+key)
    result={'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),'first':first,'second':second,'passed':True}
    if args.output:args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))

if __name__=='__main__':main()
