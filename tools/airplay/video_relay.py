"""Bounded HLS remux relay for an AirPlay receiver on the local network."""
import asyncio
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile

from aiohttp import web


class VideoRelay:
    def __init__(self):
        self.process = None
        self.runner = None
        self.directory = None
        self.stderr_task = None
        self.watch_task = None
        self.on_error = None

    @staticmethod
    def ffmpeg_path():
        base = Path(sys.executable).parent
        for path in (base.parent / 'Tools' / 'ffmpeg.exe', base.parent / 'ffmpeg.exe',
                     base / 'ffmpeg.exe', Path('C:/ProgramData/chocolatey/bin/ffmpeg.exe'),
                     Path(os.environ.get('LOCALAPPDATA', '.')) / 'Microsoft/WinGet/Links/ffmpeg.exe'):
            if path.is_file():
                return str(path)
        return shutil.which('ffmpeg')

    async def start(self, url, receiver):
        executable = self.ffmpeg_path()
        if not executable:
            raise FileNotFoundError('FFmpeg is required for relaying')
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
            route.connect((str(receiver), 7000))
            local_address = route.getsockname()[0]
        self.directory = tempfile.TemporaryDirectory(prefix='bobtv-airplay-')
        folder = Path(self.directory.name)
        token = secrets.token_urlsafe(24)

        async def serve(request):
            if request.remote != str(receiver) or request.match_info['token'] != token:
                raise web.HTTPForbidden()
            name = request.match_info['name']
            if name != 'live.m3u8' and not (name.startswith('segment') and name.endswith('.ts')
                                           and name[7:-3].isdigit()):
                raise web.HTTPNotFound()
            path = folder / name
            if not path.is_file():
                raise web.HTTPNotFound()
            content_type = 'application/vnd.apple.mpegurl' if name.endswith('.m3u8') else 'video/mp2t'
            return web.FileResponse(path, headers={'Content-Type': content_type, 'Cache-Control': 'no-store'})

        app = web.Application()
        app.router.add_get('/{token}/{name}', serve)
        self.runner = web.AppRunner(app, access_log=None)
        await self.runner.setup()
        site = web.TCPSite(self.runner, local_address, 0)
        await site.start()
        port = site._server.sockets[0].getsockname()[1]
        options = {'creationflags': subprocess.CREATE_NO_WINDOW} if sys.platform == 'win32' else {}
        self.process = await asyncio.create_subprocess_exec(
            executable, '-nostdin', '-hide_banner', '-loglevel', 'error',
            '-rw_timeout', '10000000', '-i', url,
            '-map', '0:v:0', '-map', '0:a:0?', '-c:v', 'copy',
            '-c:a', 'aac', '-b:a', '160k', '-ac', '2',
            '-f', 'hls', '-hls_time', '2', '-hls_list_size', '6',
            '-hls_delete_threshold', '2', '-hls_flags', 'delete_segments+temp_file',
            '-hls_segment_filename', str(folder / 'segment%09d.ts'),
            str(folder / 'live.m3u8'),
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE, **options)

        process = self.process
        async def drain():
            # Drain continuously without retaining URLs in memory or logs.
            while await process.stderr.read(4096):
                pass
        self.stderr_task = asyncio.create_task(drain())
        async def limit_disk():
            while process.returncode is None:
                await asyncio.sleep(2)
                total = 0
                for path in folder.iterdir():
                    try:
                        total += path.stat().st_size
                    except FileNotFoundError:
                        pass
                if total > 192 * 1024 * 1024:
                    if self.on_error:
                        self.on_error('AirPlay 視頻暫存超過上限，已停止轉發。')
                    if process.returncode is None:
                        process.kill()
                    return
        self.watch_task = asyncio.create_task(limit_disk())
        for _ in range(120):
            if (folder / 'live.m3u8').is_file():
                return f'http://{local_address}:{port}/{token}/live.m3u8'
            if self.process.returncode is not None:
                raise RuntimeError('Video remux failed')
            await asyncio.sleep(0.1)
        raise asyncio.TimeoutError('Video remux startup timed out')

    async def stop(self):
        watch, process, stderr = self.watch_task, self.process, self.stderr_task
        runner, directory = self.runner, self.directory
        self.watch_task = self.process = self.stderr_task = None
        self.runner = self.directory = None
        if watch:
            watch.cancel()
            try:
                await watch
            except asyncio.CancelledError:
                pass
        if process:
            if process.returncode is None:
                process.kill()
            await process.wait()
        if stderr:
            await stderr
        if runner:
            await runner.cleanup()
        if directory:
            directory.cleanup()
