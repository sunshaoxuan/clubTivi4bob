"""Developer-only, bounded physical-receiver test. Does not change BobTV data."""
import asyncio
import contextlib
import json
import os
import hashlib
import urllib.request
from pathlib import Path
import socket
import subprocess
import tempfile
import uuid

from aiohttp import web
import pyatv
from pyatv.const import Protocol
from mac_video import play_mac_url
from mac_frames import play_test_frames
from mac_source import FFmpegFrames


@contextlib.asynccontextmanager
async def timing_access(address):
    rule = 'BobTV-Temporary-Mac-Test-' + uuid.uuid4().hex
    async def open_port(port):
        command = (f"New-NetFirewallRule -Name '{rule}' -DisplayName '{rule}' "
                   f"-Direction Inbound -Action Allow -Protocol UDP -LocalPort {port} "
                   f"-RemoteAddress '{address}' -Profile Any | Out-Null")
        result = await asyncio.to_thread(subprocess.run,
            ['powershell', '-NoProfile', '-Command', command], check=True, timeout=20, capture_output=True)
    try:
        yield open_port
    finally:
        await asyncio.to_thread(subprocess.run,
            ['powershell', '-NoProfile', '-Command',
             f"Remove-NetFirewallRule -Name '{rule}' -ErrorAction SilentlyContinue"],
            timeout=20, capture_output=True, check=True)


async def main():
    configs = await pyatv.scan(asyncio.get_running_loop(), timeout=5,
                              protocol=Protocol.AirPlay)
    targets = [c for c in configs if c.get_service(Protocol.AirPlay).properties.get('model') == 'MacBookPro16,2']
    if len(targets) != 1:
        raise RuntimeError('Expected exactly one test Mac')
    target = targets[0]
    address = str(target.address)
    service = target.get_service(Protocol.AirPlay)
    if service.properties.get('act') == '2' or service.requires_password:
        raise RuntimeError('Receiver is access restricted; no test sent')
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
        route.connect((address, service.port))
        local = route.getsockname()[0]
    rule = 'BobTV-Temporary-Mac-Test-' + uuid.uuid4().hex
    runner = None
    task = None
    with tempfile.TemporaryDirectory(prefix='bobtv-mac-probe-') as temp:
        helper = None
        helper_hash = os.environ.get('BOBTV_PROBE_HELPER_SHA256')
        if helper_hash:
            with urllib.request.urlopen('http://100.65.248.58:8767/fpsap-probe.exe', timeout=10) as reply:
                data = reply.read(8 * 1024 * 1024)
            if hashlib.sha256(data).hexdigest() != helper_hash:
                raise RuntimeError('Probe helper hash mismatch')
            helper = str(Path(temp) / 'fpsap-probe.exe')
            Path(helper).write_bytes(data)
        if os.environ.get('BOBTV_PROBE_LIVE') == '1':
            source = FFmpegFrames('C:\\ProgramData\\chocolatey\\lib\\ffmpeg\\tools\\ffmpeg\\bin\\ffmpeg.exe', test=True)
            try:
                await source.start()
                async with timing_access(address) as timing_ready:
                    await asyncio.wait_for(play_test_frames(address, service.port, None, helper,
                        lambda item: print(json.dumps(item), flush=True), source=source,
                        timing_ready=timing_ready), 45)
            except asyncio.TimeoutError:
                print(json.dumps({'stage': 'live-test', 'result': 'bounded-test-stopped'}), flush=True)
            except Exception as error:
                print(json.dumps({'stage': 'live-test', 'errorType': type(error).__name__}), flush=True)
            finally:
                process = source.process
                await source.close()
                print(json.dumps({'stage': 'live-cleanup', 'decoderExited': process is None or process.returncode is not None}), flush=True)
            return
        if os.environ.get('BOBTV_PROBE_FRAMES') == '1':
            raw = Path(temp) / 'test.h264'
            pcm = Path(temp) / 'test.pcm'
            process = await asyncio.create_subprocess_exec(
                'C:\\ProgramData\\chocolatey\\bin\\ffmpeg.exe', '-hide_banner', '-loglevel', 'error',
                '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=25',
                '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100',
                '-map', '0:v', '-t', '8',
                '-vf', "drawtext=fontfile='C\\:/Windows/Fonts/arial.ttf':text='FRAME %{n}':fontsize=64:fontcolor=white:box=1:boxcolor=black:x=20:y=20",
                '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency',
                '-profile:v', 'baseline', '-pix_fmt', 'yuv420p', '-g', '25',
                '-x264-params', 'aud=1:repeat-headers=1', '-f', 'h264', str(raw),
                '-map', '1:a', '-t', '8', '-af', 'volume=0.25', '-ac', '2',
                '-c:a', 'pcm_s16le', '-f', 's16le', str(pcm),
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
            try:
                if await asyncio.wait_for(process.wait(), 30):
                    raise RuntimeError('Test frame generation failed')
            finally:
                if process.returncode is None:
                    process.kill()
                    await process.wait()
            try:
                async with timing_access(address) as timing_ready:
                    await asyncio.wait_for(play_test_frames(address, service.port, raw.read_bytes(), helper,
                        lambda item: print(json.dumps(item), flush=True), pcm.read_bytes(),
                        timing_ready=timing_ready), 45)
            except Exception as error:
                print(json.dumps({'stage': 'frame-test', 'errorType': type(error).__name__}), flush=True)
            return
        video = Path(temp) / 'test.m3u8'
        process = await asyncio.create_subprocess_exec(
            'C:\\ProgramData\\chocolatey\\bin\\ffmpeg.exe', '-hide_banner', '-loglevel', 'error',
            '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=25',
            '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
            '-t', '20', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
            '-c:a', 'aac', '-af', 'volume=0.05', '-g', '50',
            '-f', 'hls', '-hls_time', '2', '-hls_list_size', '0', str(video),
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
        try:
            if await asyncio.wait_for(process.wait(), 30):
                raise RuntimeError('Test video generation failed')
        finally:
            if process.returncode is None:
                process.kill()
                await process.wait()
        hits = []
        token = uuid.uuid4().hex

        async def media(request):
            if request.remote != address:
                raise web.HTTPForbidden()
            name = request.match_info['name']
            if name != 'test.m3u8' and not (name.startswith('test') and name.endswith('.ts')
                                           and name[4:-3].isdigit()):
                raise web.HTTPNotFound()
            hits.append(name)
            return web.FileResponse(Path(temp) / name)

        app = web.Application()
        async def health(request):
            if request.remote != address:
                raise web.HTTPForbidden()
            return web.Response(text='bobtv-probe-ready')
        app.router.add_get('/health', health)
        app.router.add_get('/' + token + '/{name}', media)
        runner = web.AppRunner(app, access_log=None)
        await runner.setup()
        site = web.TCPSite(runner, local, int(os.environ.get('BOBTV_PROBE_PORT', '0')))
        await site.start()
        port = site._server.sockets[0].getsockname()[1]
        try:
            command = (f"New-NetFirewallRule -Name '{rule}' -DisplayName '{rule}' "
                       f"-Direction Inbound -Action Allow -Protocol TCP -LocalPort {port} "
                       f"-RemoteAddress '{address}' -Profile Any | Out-Null")
            subprocess.run(['powershell', '-NoProfile', '-Command', command],
                           check=True, timeout=20, capture_output=True)
            task = asyncio.create_task(play_mac_url(address, service.port,
                                       f'http://{local}:{port}/{token}/test.m3u8',
                                       diagnostic=lambda item: print(json.dumps(item)),
                                       url_only=True, media_auth_helper=helper))
            try:
                await asyncio.wait_for(task, 35)
                print(json.dumps({'stage':'video', 'result':'session-ended', 'mediaRequests':hits}))
            except Exception as error:
                print(json.dumps({'stage':'video', 'errorType':type(error).__name__,
                                  'mediaRequests':hits}))
        finally:
            if task and not task.done():
                task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await task
            await runner.cleanup()
            subprocess.run(['powershell', '-NoProfile', '-Command',
                            f"Remove-NetFirewallRule -Name '{rule}' -ErrorAction SilentlyContinue"],
                           timeout=20, capture_output=True, check=True)


if __name__ == '__main__':
    asyncio.run(main())
