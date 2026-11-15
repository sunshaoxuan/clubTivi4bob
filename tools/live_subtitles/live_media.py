"""Bounded live HLS collection, preserving interruption and media clock evidence."""
import argparse
import concurrent.futures
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import threading
import time
from urllib.parse import urljoin, urlsplit
from urllib.request import Request, urlopen


def fetch(url, limit=16 * 1024 * 1024):
    if urlsplit(url).scheme != 'https':
        raise ValueError('https_required')
    with urlopen(Request(url, headers={'User-Agent': 'BobTV-LiveSubtitle/1.0'}), timeout=12) as response:
        raw = response.read(limit + 1)
    if len(raw) > limit:
        raise ValueError('response_limit')
    return raw


def parse_media(raw, url):
    lines = raw.splitlines()
    sequence = int(next(x.split(':', 1)[1] for x in lines if x.startswith('#EXT-X-MEDIA-SEQUENCE:')))
    key, tags, duration, discontinuity = None, [], None, False
    output = []
    for line in lines:
        if line.startswith('#EXT-X-KEY:'):
            key = None if 'METHOD=NONE' in line else line
        elif line == '#EXT-X-DISCONTINUITY':
            discontinuity = True
        elif line.startswith('#EXTINF:'):
            duration = float(line.split(':', 1)[1].split(',')[0])
            tags.append(line)
        elif line.startswith(('#EXT-X-ASSET:', '#EXT-X-CUE', '#EXT-X-DATERANGE')):
            tags.append(line)
        elif line and not line.startswith('#') and duration is not None:
            if not math.isfinite(duration) or not 0 < duration <= 30:
                raise ValueError('invalid_segment_duration')
            segment = urljoin(url, line)
            joined = '\n'.join(tags)
            episode = re.search(r'epid=([^:,\s\"]+)', joined)
            caid = re.search(r'CAID="([^"]+)"', joined)
            path = urlsplit(segment).path
            output.append(dict(sequence=sequence, duration=duration, url=segment, tags=tags,
                               key=key, discontinuity=discontinuity,
                               contentId=episode[1] if episode else None,
                               caid=caid[1] if caid else None,
                               asset=path.rsplit('/media-', 1)[0], sourcePath=path))
            sequence += 1
            tags, duration, discontinuity = [], None, False
    return output


class Collector:
    def __init__(self, source, root, *, seconds=7200):
        self.source, self.root, self.seconds = source, Path(root), seconds
        (self.root / 'segments').mkdir(parents=True, exist_ok=True)
        (self.root / 'manifests').mkdir(exist_ok=True)
        self.rows, self.keys = [], {}
        self.lock, self.stop = threading.RLock(), threading.Event()
        self.errors = []

    def log(self, kind, **facts):
        item = dict(event=kind, wall=time.time(), **facts)
        with (self.root / 'events.jsonl').open('a') as file:
            file.write(json.dumps(item) + '\n')

    def run(self):
        started, elapsed, last = time.monotonic(), 0., None
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            while not self.stop.is_set() and (self.seconds <= 0 or time.monotonic() - started < self.seconds):
                try:
                    raw = fetch(self.source).decode()
                    observed = time.time()
                    parsed = parse_media(raw, self.source)
                    if not parsed:
                        raise ValueError('not_media_playlist')
                    (self.root / 'manifests' / (str(parsed[0]['sequence']) + '.m3u8')).write_text(raw)
                    fresh = [x for x in parsed if last is None or x['sequence'] > last]
                    if last is None:
                        # Enough media for acoustic bootstrap and startup headroom.
                        chosen, length = [], 0
                        for row in reversed(fresh):
                            chosen.insert(0, row)
                            length += row['duration']
                            if length >= 30:
                                break
                        fresh = chosen
                    jobs = {x['sequence']: pool.submit(fetch, x['url']) for x in fresh}
                    for row in fresh:
                        binary = jobs[row['sequence']].result()
                        path = self.root / 'segments' / (str(row['sequence']) + '.ts')
                        path.write_bytes(binary)
                        line = row.pop('key')
                        if line:
                            match = re.search(r'URI="([^"]+)"', line)
                            if not match or 'METHOD=AES-128' not in line:
                                raise ValueError('unsupported_key')
                            key_url = urljoin(self.source, match[1])
                            if key_url not in self.keys:
                                key_path = self.root / 'segments' / ('key-' + hashlib.sha256(key_url.encode()).hexdigest()[:20] + '.bin')
                                key = fetch(key_url, 16)
                                if len(key) != 16:
                                    raise ValueError('invalid_key_size')
                                key_path.write_bytes(key)
                                key_path.chmod(0o600)
                                self.keys[key_url] = str(key_path)
                            line = line.replace(match[1], self.keys[key_url])
                        gap = last is not None and row['sequence'] != last + 1
                        record = {k: v for k, v in row.items() if k != 'url'}
                        record.update(timelineStart=elapsed, timelineEnd=elapsed + row['duration'],
                                      observedWall=observed, downloadedWall=time.time(),
                                      localPath=str(path), keyLine=line, sequenceGap=gap)
                        with self.lock:
                            self.rows.append(record)
                            with (self.root / 'segments.jsonl').open('a') as file:
                                file.write(json.dumps(record) + '\n')
                            cutoff = record['timelineEnd'] - 7200
                            expired = [r for r in self.rows if r['timelineEnd'] < cutoff]
                            self.rows = [r for r in self.rows if r['timelineEnd'] >= cutoff]
                            for previous in expired:
                                Path(previous['localPath']).unlink(missing_ok=True)
                                (self.root / 'normalized' / (str(previous['sequence'])+'.ts')).unlink(missing_ok=True)
                        if gap:
                            self.log('sequence_gap', previous=last, next=row['sequence'])
                        if len(self.rows) == 1 or self.rows[-2]['asset'] != record['asset']:
                            self.log('asset_change', sequence=record['sequence'], timeline=elapsed,
                                     contentId=record['contentId'], caid=record['caid'], tags=record['tags'])
                        elapsed, last = record['timelineEnd'], record['sequence']
                except Exception as error:
                    self.errors.append(type(error).__name__)
                    self.log('collector_error', errorType=type(error).__name__)
                self.stop.wait(1)

    def snapshot(self):
        with self.lock:
            return list(self.rows)


def playlist(rows, *, uri=lambda r: r['localPath'], local_keys=True, end=False):
    if not rows:
        return '#EXTM3U\n'
    lines = ['#EXTM3U', '#EXT-X-VERSION:6', '#EXT-X-TARGETDURATION:' + str(math.ceil(max(r['duration'] for r in rows))),
             '#EXT-X-MEDIA-SEQUENCE:' + str(rows[0]['sequence']), '#EXT-X-START:TIME-OFFSET=0.0,PRECISE=YES']
    previous = object()
    for row in rows:
        if row['discontinuity'] or row.get('sequenceGap'):
            lines.append('#EXT-X-DISCONTINUITY')
        key = row['keyLine']
        if key != previous:
            previous = key
            if key and not local_keys:
                key = re.sub(r'URI="([^"]+)"', lambda m: 'URI="segments/' + Path(m[1]).name + '"', key)
            lines.append(key or '#EXT-X-KEY:METHOD=NONE')
        lines.extend([f"#EXTINF:{row['duration']},", uri(row)])
    if end:
        lines.append('#EXT-X-ENDLIST')
    return '\n'.join(lines) + '\n'


def normalize_segment(row, ffmpeg, root):
    """Remux without transcoding onto the collector's continuous media clock.

    Provider ad PTS can jump by minutes without a discontinuity tag. Serving
    those raw timestamps makes a player's decoded clock diverge from EXTINF.
    Source media/PTS remain private and unchanged for acoustic verification.
    """
    root=Path(root);folder=root/'normalized';folder.mkdir(exist_ok=True)
    target=folder/(str(row['sequence'])+'.ts')
    if target.exists():return target
    manifest=folder/(str(row['sequence'])+'.m3u8');manifest.write_text(playlist([row],end=True))
    temporary=folder/(str(row['sequence'])+'.tmp.ts')
    subprocess.run([ffmpeg,'-hide_banner','-loglevel','error','-copyts','-start_at_zero',
        '-protocol_whitelist','file,crypto,data','-allowed_extensions','ALL','-i',str(manifest),
        '-map','0:v:0','-map','0:a:0','-c','copy','-mpegts_copyts','1','-muxdelay','0','-muxpreload','0',
        '-output_ts_offset',str(row['timelineStart']),'-y',str(temporary)],
        timeout=12,capture_output=True,check=True)
    if temporary.stat().st_size<188:raise ValueError('empty_normalized_media')
    os.replace(temporary,target);return target


if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('--source', required=True); p.add_argument('--output', required=True); p.add_argument('--seconds', type=int, default=7200)
    a = p.parse_args(); Collector(a.source, a.output, seconds=a.seconds).run()
