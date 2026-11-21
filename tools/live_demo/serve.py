#!/usr/bin/env python3
"""Small, inspectable HLS live demo. No app code or third-party TV lists.

Streams are real-time loops of CC-BY-3.0 trailers and an original test pattern.
The incoming .bobtv package always points to moving HLS windows, never MP4 files.
"""
import argparse
import datetime as dt
import hashlib
import html
import json
import os
import re
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
import urllib.request
import xml.etree.ElementTree as ET
import zlib

ASSETS = [
    dict(id='bunny', name='开放动画直播 · Big Buck Bunny',
         source='https://media.w3.org/2010/05/bunny/trailer.mp4',
         project='https://peach.blender.org/about/',
         credit='(c) 2008 Blender Foundation | Big Buck Bunny trailer',
         origin='peach.blender.org', sha256='b2ded9ae5a20fa36ca8cec49ef923bffb5e1a51d9e8c1f8336273d2fa9d35ff0'),
    dict(id='sintel', name='开放动画直播 · Sintel',
         source='https://media.w3.org/2010/05/sintel/trailer.mp4',
         project='https://durian.blender.org/sharing/',
         credit='(c) Blender Foundation | Sintel trailer',
         origin='durian.blender.org', sha256='b670602fa00934ca27c4351bb0efe7ea7a07fae57284e44226025eeed7c51254'),
]
LICENSE = 'https://creativecommons.org/licenses/by/3.0/'


def base_url(value):
    parsed = urlsplit(value)
    if parsed.scheme not in ('http', 'https') or not parsed.netloc or parsed.username or parsed.query or parsed.fragment:
        raise ValueError('Use an absolute HTTP(S) base URL without credentials, query or fragment')
    return value.rstrip('/')


def package(base):
    base = base_url(base)
    return dict(format='bobtv-resource', schemaVersion=1, id='bobtv-open-hls-live-demo',
                name='BobTV 开放授权 HLS 直播范例', revision='2026-11-20.1',
                updateUrl=base+'/demo.bobtv',
                categories=[dict(id='animation', name='开放动画直播'), dict(id='signal', name='直播测试信号')],
                epgSources=[dict(id='demo', url=base+'/epg.xml')],
                channels=[dict(id=a['id'], name=a['name'], categoryId='animation',
                               logo=base+'/logos/'+a['id']+'.png',
                               epg=dict(sourceId='demo', channelId=a['id']),
                               routes=[dict(id='hls', url=base+'/hls/'+a['id']+'/master.m3u8')]) for a in ASSETS]+
                         [dict(id='signal', name='BobTV 实时测试信号', categoryId='signal',
                               logo=base+'/logos/signal.png', epg=dict(sourceId='demo', channelId='signal'),
                               routes=[dict(id='hls', url=base+'/hls/signal/master.m3u8')])])


def download(asset, directory):
    path = directory/(asset['id']+'.mp4')
    if not path.exists():
        partial = path.with_suffix('.part')
        try:
            request = urllib.request.Request(asset['source'], headers={'User-Agent':'BobTV-open-live-demo/1.0'})
            with urllib.request.urlopen(request, timeout=30) as response, partial.open('wb') as file:
                count = 0
                while True:
                    chunk = response.read(65536)
                    if not chunk: break
                    count += len(chunk)
                    if count > 64*1024*1024: raise ValueError('Demo input exceeds 64 MiB')
                    file.write(chunk)
            partial.replace(path)
        finally:
            partial.unlink(missing_ok=True)
    if path.stat().st_size == 0: raise ValueError('Empty input file')
    digest=hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != asset['sha256']: raise ValueError('Input differs from the reviewed fixture: '+asset['id'])
    return path, digest


def logo(path, color):
    # Original geometric artwork; no Blender, W3C or broadcaster trademarks.
    width, height = 160, 90
    data = bytearray()
    for y in range(height):
        data.append(0)
        for x in range(width):
            data.extend((244, 245, 255) if 65 <= x <= 101 and abs(y-45) <= (101-x)*0.65 else color)
    def chunk(kind, data):
        return struct.pack('>I', len(data))+kind+data+struct.pack('>I', zlib.crc32(kind+data))
    path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>IIBBBBB',width,height,8,2,0,0,0))+
                     chunk(b'IDAT',zlib.compress(bytes(data)))+chunk(b'IEND',b''))


def epg():
    tv = ET.Element('tv', {'generator-info-name':'BobTV demo schedule (not broadcaster EPG)'})
    at = dt.datetime.now(dt.timezone.utc).replace(minute=0,second=0,microsecond=0)
    for asset in ASSETS+[dict(id='signal',name='BobTV 实时测试信号')]:
        channel = ET.SubElement(tv,'channel',id=asset['id'])
        ET.SubElement(channel,'display-name').text=asset['name']
        for hour in range(-1,25):
            start=at+dt.timedelta(hours=hour);stop=start+dt.timedelta(hours=1)
            programme=ET.SubElement(tv,'programme',channel=asset['id'],start=start.strftime('%Y%m%d%H%M%S +0000'),stop=stop.strftime('%Y%m%d%H%M%S +0000'))
            ET.SubElement(programme,'title',lang='zh').text=asset['name']+'（演示编排）'
            ET.SubElement(programme,'desc',lang='zh').text='开放授权素材连续轮播或实时生成测试信号；非现场摄像直播。'
    return ET.tostring(tv,encoding='utf-8',xml_declaration=True)


def font_path(value):
    for item in [value, '/System/Library/Fonts/Supplemental/Arial.ttf',
                 '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf']:
        if item and Path(item).is_file(): return str(Path(item).resolve())
    raise ValueError('Provide --font with a TrueType font file')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir',type=Path,required=True)
    parser.add_argument('--ffmpeg',default=shutil.which('ffmpeg'))
    parser.add_argument('--font')
    parser.add_argument('--bind',default='127.0.0.1')
    parser.add_argument('--port',type=int,default=18767)
    parser.add_argument('--public-base')
    args=parser.parse_args()
    if not args.ffmpeg: parser.error('Provide --ffmpeg or install FFmpeg with drawtext/libx264/AAC')
    args.ffmpeg=shutil.which(args.ffmpeg)
    if not args.ffmpeg:parser.error('FFmpeg executable is not available')
    if not 1<=args.port<=65535:parser.error('Port must be between 1 and 65535')
    def stop(signum, frame): raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, stop)
    base=base_url(args.public_base or 'http://127.0.0.1:'+str(args.port));font=font_path(args.font)
    root=args.work_dir.expanduser().resolve();root.mkdir(parents=True,exist_ok=True)
    marker=root/'.bobtv-live-demo'
    if any(root.iterdir()) and not marker.exists(): parser.error('Work directory is nonempty and is not owned by this tool')
    marker.touch()
    (root/'inputs').mkdir(exist_ok=True);(root/'logos').mkdir(exist_ok=True)
    manifest=package(base)
    (root/'demo.bobtv').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    evidence=[]
    for index,asset in enumerate(ASSETS):
        path,digest=download(asset,root/'inputs')
        asset['input']=path
        evidence.append(dict(id=asset['id'],source=asset['source'],license=LICENSE,
                             rights=asset['project'],sha256=digest,bytes=path.stat().st_size,
                             changes='Looped, scaled and transcoded to live HLS with a credit overlay; no trimming.'))
        logo(root/'logos'/(asset['id']+'.png'),[(73,56,170),(37,102,143)][index])
    logo(root/'logos/signal.png',(32,122,88))
    (root/'provenance.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n')
    credits='<h1>BobTV live demo credits</h1><p>Openly licensed trailers, continuously streamed. Not live camera footage. No endorsement implied.</p>'
    for asset in ASSETS:
        credits+='<p>'+html.escape(asset['credit'])+'<br><a href="'+asset['project']+'">Project license statement</a> | <a href="'+LICENSE+'">CC BY 3.0</a><br>Looped, scaled, re-encoded with credits overlaid; no trimming.</p>'
    credits+='<p>Test signal and geometric logos: generated for this demo; CC0. <a href="https://creativecommons.org/publicdomain/zero/1.0/">CC0 terms</a></p>'
    (root/'index.html').write_text('<!doctype html><meta charset="utf-8"><title>BobTV HLS Live Demo</title><h1>BobTV HLS Live Demo</h1><p>Real-time looping streams, not live camera footage.</p><p><a href="demo.bobtv">Download BobTV package</a> | <a href="CREDITS.html">Credits and licenses</a></p>')
    (root/'CREDITS.html').write_text('<!doctype html><meta charset="utf-8"><title>Live demo credits</title>'+credits)
    class Handler(SimpleHTTPRequestHandler):
        def __init__(self,*pos,**kw):super().__init__(*pos,directory=str(root),**kw)
        def do_GET(self):
            path=urlsplit(self.path).path
            allowed=(path in ('/','/index.html','/demo.bobtv','/CREDITS.html','/provenance.json','/epg.xml')
                or re.fullmatch(r'/logos/(?:bunny|sintel|signal)\.png',path)
                or re.fullmatch(r'/hls/(?:bunny|sintel|signal)/(?:master\.m3u8|index\.m3u8|segment_\d{10}\.ts)',path))
            if not allowed:
                self.send_error(404)
            elif path=='/epg.xml':
                body=epg();self.send_response(200);self.send_header('Content-Type','application/xml; charset=utf-8')
                self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(body)))
                self.end_headers()
                if self.command!='HEAD':self.wfile.write(body)
            elif self.command=='HEAD':super().do_HEAD()
            else:super().do_GET()
        def do_HEAD(self):
            # Use the same public path policy and headers as GET.
            self.do_GET()
        def end_headers(self):
            if self.path.split('?')[0].endswith(('.m3u8','.bobtv')):self.send_header('Cache-Control','no-store')
            super().end_headers()
        def log_message(self,fmt,*values):pass
    server=ThreadingHTTPServer((args.bind,args.port),Handler)
    server.daemon_threads=True
    processes=[];logs=[];thread=None
    try:
        for asset in ASSETS+[dict(id='signal')]:
            directory=root/'hls'/asset['id'];directory.mkdir(parents=True,exist_ok=True)
            (directory/'master.m3u8').write_text('#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-STREAM-INF:BANDWIDTH=950000,AVERAGE-BANDWIDTH=714000,CODECS="avc1.42C01E,mp4a.40.2",RESOLUTION=640x360,FRAME-RATE=24.000\nindex.m3u8\n')
            # Restart only removes this tool's regenerable playlist and segments.
            for path in directory.glob('*.ts'):path.unlink()
            (directory/'index.m3u8').unlink(missing_ok=True)
            text=(asset['credit']+'\nCC BY 3.0 | creativecommons.org/licenses/by/3.0/\n'+
                  asset['origin']+' | Loop, scale, HLS and credit overlay by BobTV') if 'credit' in asset else \
                 'BobTV original test signal | generated live\nCC0 | creativecommons.org/publicdomain/zero/1.0/'
            textfile=directory/'credits.txt';textfile.write_text(text)
            def escape(value):return str(value).replace('\\','\\\\').replace(':','\\:').replace("'", "'\\''")
            vf="scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2,setsar=1,"+\
               "drawbox=x=0:y=ih-66:w=iw:h=66:color=black@0.78:t=fill,"+\
               "drawtext=fontfile='"+escape(font)+"':textfile='"+escape(textfile)+"':expansion=none:fontsize=11:fontcolor=white:x=9:y=h-59:line_spacing=4"
            inputs=['-re','-stream_loop','-1','-i',str(asset['input'])] if 'input' in asset else \
                   ['-re','-f','lavfi','-i','testsrc2=size=640x360:rate=24','-f','lavfi','-i','sine=frequency=440:sample_rate=48000']
            command=[args.ffmpeg,'-hide_banner','-loglevel','warning','-nostdin','-y']+inputs+\
                ['-map','0:v:0','-map','0:a:0' if 'input' in asset else '1:a:0','-vf',vf,'-r','24',
                 '-c:v','libx264','-threads','2','-preset','veryfast','-profile:v','baseline','-level:v','3.0','-tune','zerolatency','-bf','0','-pix_fmt','yuv420p','-g','72','-keyint_min','72','-sc_threshold','0',
                 '-b:v','650k','-maxrate','800k','-bufsize','1600k','-c:a','aac','-b:a','64k','-ac','2','-ar','48000',
                 '-f','hls','-hls_time','3','-hls_list_size','6','-hls_delete_threshold','2',
                 '-hls_flags','delete_segments+independent_segments+omit_endlist+program_date_time+temp_file',
                 '-hls_segment_filename',str(directory/'segment_%010d.ts'),str(directory/'index.m3u8')]
            log=(directory/'encoder.log').open('wb');logs.append(log)
            processes.append(subprocess.Popen(command,stdout=subprocess.DEVNULL,stderr=log))
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        deadline=time.monotonic()+40
        while time.monotonic()<deadline:
            if any(p.poll() is not None for p in processes):raise RuntimeError('Encoder exited; see hls/*/encoder.log')
            if all((root/'hls'/a['id']/'index.m3u8').exists() for a in manifest['channels']):break
            time.sleep(.2)
        else:raise RuntimeError('Live playlists did not become ready')
        print('Package: '+base+'/demo.bobtv',flush=True)
        print('Credits: '+base+'/CREDITS.html',flush=True)
        while True:
            if any(p.poll() is not None for p in processes):raise RuntimeError('Live encoder stopped')
            time.sleep(1)
    except KeyboardInterrupt:pass
    finally:
        for p in processes:
            if p.poll() is None:p.terminate()
        for p in processes:
            try:p.wait(timeout=8)
            except subprocess.TimeoutExpired:p.kill();p.wait()
        if thread is not None:server.shutdown()
        server.server_close()
        for log in logs:log.close()

if __name__=='__main__':main()
