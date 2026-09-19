"""Bounded elementary-video parser for a future live FFmpeg sender pipeline.

Does not retain an entire broadcast. Access units require FFmpeg's aud=1 option.
"""
import re
import struct
import asyncio
import contextlib
import subprocess
import sys

from mac_audio import PCM_BYTES


class AnnexBFrames:
    def __init__(self, max_bytes=2 * 1024 * 1024):
        self.max_bytes = max_bytes
        self.buffer = bytearray()
        self.nals = []
        self.frame_bytes = 0
        self.sps = self.pps = None

    @property
    def config(self):
        if not self.sps or not self.pps:
            return None
        return (b'\x01' + self.sps[1:4] + b'\xff\xe1'
                + struct.pack('>H', len(self.sps)) + self.sps + b'\x01'
                + struct.pack('>H', len(self.pps)) + self.pps)

    def _consume(self, nal, frames):
        if not nal:
            return
        kind = nal[0] & 31
        if kind in (7, 8):
            if len(nal) > 65535 or (kind == 7 and len(nal) < 4):
                raise ValueError('Invalid H.264 parameter set')
            if kind == 7:
                self.sps = bytes(nal)
            else:
                self.pps = bytes(nal)
        if kind == 9 and self.nals:
            frames.append(self.nals)
            self.nals = []
            self.frame_bytes = 0
        if 1 <= kind <= 5:
            self.frame_bytes += len(nal)
            if self.frame_bytes > self.max_bytes:
                raise ValueError('H.264 frame exceeds memory limit')
            self.nals.append(bytes(nal))

    def feed(self, data, final=False):
        if len(data) > self.max_bytes:
            raise ValueError('H.264 input chunk exceeds memory limit')
        self.buffer.extend(data)
        frames = []
        boundaries = list(re.finditer(b'\x00\x00\x00?\x01', self.buffer))
        for first, second in zip(boundaries, boundaries[1:]):
            self._consume(self.buffer[first.end():second.start()], frames)
        if boundaries:
            last = boundaries[-1]
            if final:
                self._consume(self.buffer[last.end():], frames)
                self.buffer.clear()
            else:
                del self.buffer[:last.start()]
        if len(self.buffer) > self.max_bytes:
            raise ValueError('H.264 NAL exceeds memory limit')
        if final and self.nals:
            frames.append(self.nals)
            self.nals = []
            self.frame_bytes = 0
        return frames


class FFmpegFrames:
    """One decoder process with separately backpressured video/audio pipes."""

    def __init__(self, executable, url=None, test=False):
        self.executable, self.url, self.test = executable, url, test
        self.process = self.server = self.audio_writer = self.stderr_task = None
        self.audio_reader = None
        self.test_error_tail = b''
        self.parser = AnnexBFrames()
        self.width, self.height = 1280, 720

    async def start(self):
        loop = asyncio.get_running_loop()
        connected = loop.create_future()
        self.connected = connected

        def accept(reader, writer):
            if self.audio_reader is not None:
                writer.close()
                return
            self.audio_reader, self.audio_writer = reader, writer
            if not connected.done():
                connected.set_result(None)

        self.server = await asyncio.start_server(accept, '127.0.0.1', 0, limit=32768)
        port = self.server.sockets[0].getsockname()[1]
        if self.test:
            inputs = ['-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=25',
                      '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100']
            audio_map = '1:a:0'
        else:
            from urllib.parse import urlsplit
            if urlsplit(self.url or '').scheme not in ('http', 'https'):
                raise ValueError('Live casting requires an HTTP(S) source')
            inputs = ['-rw_timeout', '10000000', '-i', self.url]
            audio_map = '0:a:0'
        options = {'creationflags': subprocess.CREATE_NO_WINDOW} if sys.platform == 'win32' else {}
        video_filter = 'scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,fps=25'
        if self.test:
            video_filter += ",drawtext=fontfile='C\\:/Windows/Fonts/arial.ttf':text='LIVE FRAME %{n}':fontsize=64:fontcolor=white:box=1:boxcolor=black:x=20:y=20"
        self.process = await asyncio.create_subprocess_exec(
            self.executable, '-nostdin', '-hide_banner', '-loglevel', 'error', '-threads', '2',
            *inputs,
            '-map', '0:v:0', '-an', '-vf',
            video_filter,
            '-c:v', 'libx264', '-threads', '2', '-preset', 'veryfast', '-tune', 'zerolatency',
            '-profile:v', 'baseline', '-pix_fmt', 'yuv420p', '-b:v', '4000k',
            '-maxrate', '5000k', '-bufsize', '1000k', '-g', '25',
            '-x264-params', 'aud=1:repeat-headers=1', '-f', 'h264', 'pipe:1',
            '-map', audio_map, '-vn', '-ac', '2', '-ar', '44100',
            '-af', 'aresample=async=1:first_pts=0', '-c:a', 'pcm_s16le', '-f', 's16le',
            f'tcp://127.0.0.1:{port}',
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, limit=65536, **options)

        async def drain_errors():
            # Source URLs and token-bearing FFmpeg errors never enter logs.
            while True:
                chunk = await self.process.stderr.read(4096)
                if not chunk:
                    break
                if self.test:
                    self.test_error_tail = (self.test_error_tail + chunk)[-4096:]
        self.stderr_task = asyncio.create_task(drain_errors())
        # Do not wait for the second FFmpeg output before draining the first.
        # Windows pipe capacity can otherwise deadlock startup.

    async def video(self):
        while True:
            data = await asyncio.wait_for(self.process.stdout.read(65536), 10)
            for frame in self.parser.feed(data, final=not data):
                if not self.parser.config:
                    raise ValueError('Video lacks decoder configuration')
                yield self.parser.config, frame
            if not data:
                return

    async def audio(self):
        await asyncio.wait_for(self.connected, 15)
        self.server.close()
        # On Python 3.12 Server.wait_closed also waits for accepted clients.
        # Consume the accepted audio connection before awaiting server closure.
        while True:
            try:
                yield await asyncio.wait_for(self.audio_reader.readexactly(PCM_BYTES), 10)
            except asyncio.IncompleteReadError:
                return

    async def close(self):
        if self.process and self.process.returncode is None:
            if sys.platform == 'win32':
                killer = await asyncio.create_subprocess_exec(
                    'taskkill.exe', '/PID', str(self.process.pid), '/T', '/F',
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                    creationflags=subprocess.CREATE_NO_WINDOW)
                with contextlib.suppress(asyncio.TimeoutError):
                    await asyncio.wait_for(killer.wait(), 3)
            if self.process.returncode is None:
                self.process.kill()
        if self.audio_writer:
            self.audio_writer.close()
            with contextlib.suppress(Exception):
                await asyncio.wait_for(self.audio_writer.wait_closed(), 2)
        if self.server:
            self.server.close()
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self.server.wait_closed(), 2)
        if self.process:
            with contextlib.suppress(Exception):
                await asyncio.wait_for(self.process.wait(), 3)
        if self.stderr_task:
            self.stderr_task.cancel()
            await asyncio.gather(self.stderr_task, return_exceptions=True)
        self.process = self.server = self.audio_writer = self.stderr_task = None
