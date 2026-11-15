"""Replay an actual captured ad cycle through the client session protocol.

Only local, already acquired evidence is read. No subtitle generation or
translation. This fixture is intentionally not a production discovery service.
"""
import argparse
import json
import subprocess
import uuid
from pathlib import Path
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ffmpeg', required=True)
    parser.add_argument('--port', type=int, default=18768)
    args = parser.parse_args()
    root = args.capture.resolve()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    read = lambda name: [json.loads(line) for line in (root / name).read_text().splitlines()]
    result = json.loads((root / 'cycle-result.json').read_text())
    lo, hi = result['pause']['mediaStart'] - 30, result['return']['mediaStart'] + 90
    rows = [row for row in read('segments.jsonl') if lo <= row['timelineStart'] < hi]
    origin = rows[0]['timelineStart']
    playlist = ['#EXTM3U', '#EXT-X-VERSION:6', '#EXT-X-TARGETDURATION:6',
                '#EXT-X-MEDIA-SEQUENCE:' + str(rows[0]['sequence'])]
    last_key = None
    for row in rows:
        if row['discontinuity']:
            playlist.append('#EXT-X-DISCONTINUITY')
        if row['keyLine'] != last_key:
            last_key = row['keyLine']
            playlist.append(last_key or '#EXT-X-KEY:METHOD=NONE')
        playlist.extend([f"#EXTINF:{row['duration']},", row['localPath']])
    playlist.append('#EXT-X-ENDLIST')
    path = out / 'original-cycle.m3u8'
    path.write_text('\n'.join(playlist) + '\n')
    movie = out / 'original-cycle.mp4'
    if not movie.exists():
        subprocess.run([args.ffmpeg, '-hide_banner', '-loglevel', 'warning', '-y',
                        '-protocol_whitelist', 'file,crypto,data', '-allowed_extensions', 'ALL',
                        '-i', str(path), '-map', '0:v:0', '-map', '0:a:0',
                        '-c', 'copy', '-avoid_negative_ts', 'make_zero', '-movflags', '+faststart',
                        str(movie)], check=True)
    records = {row['sequence']: row for row in rows}
    windows = []
    for decision in read('caption-decisions.jsonl'):
        row = records.get(decision['sequence'])
        if row is None:
            continue
        cues = [{**cue, 'start': cue['start'] - origin, 'end': cue['end'] - origin}
                for cue in decision['cues']]
        windows.append(dict(start=row['timelineStart'] - origin,
                            end=row['timelineEnd'] - origin, state=decision['state'],
                            program=row['contentId'], asset=row['asset'], tracks=[
                                dict(language='zh-CN', verified=True, cues=cues)]))
    source = f'http://127.0.0.1:{args.port}/action-movies-replay'
    manifest = dict(session=uuid.uuid4().hex, source=source,
                    playbackUrl=f'http://127.0.0.1:{args.port}/original-cycle.mp4', windows=windows)
    (out / 'fixture.json').write_text(json.dumps(dict(origin=origin,
        adStart=result['pause']['mediaStart'] - origin,
        movieReturn=result['return']['mediaStart'] - origin,
        duration=rows[-1]['timelineEnd'] - origin,
        originalHoldout=result['holdout'], manifest=manifest), ensure_ascii=False))

    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(out), **kw)

        def log_message(self, *a):
            pass

        def send_manifest(self):
            data = json.dumps(manifest, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            data = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
            if self.path != '/sessions' or data.get('source') != source:
                self.send_error(404)
                return
            self.send_manifest()

        def do_GET(self):
            if self.path == '/sessions/' + manifest['session']:
                self.send_manifest()
            else:
                super().do_GET()

    print(json.dumps(dict(source=source, duration=rows[-1]['timelineEnd'] - origin)), flush=True)
    ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()


if __name__ == '__main__':
    main()
