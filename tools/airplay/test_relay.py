import asyncio
from pathlib import Path
import tempfile
import unittest
from aiohttp import ClientSession
from video_relay import VideoRelay


@unittest.skipUnless(VideoRelay.ffmpeg_path(), 'FFmpeg is required')
class RelayTests(unittest.IsolatedAsyncioTestCase):
    async def test_remux_serving_token_and_cleanup(self):
        relay = VideoRelay()
        with tempfile.TemporaryDirectory() as folder:
            video = str(Path(folder) / 'fixture.mp4')
            process = await asyncio.create_subprocess_exec(
                VideoRelay.ffmpeg_path(), '-hide_banner', '-loglevel', 'error',
                '-f', 'lavfi', '-i', 'testsrc=size=160x90:rate=25',
                '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '24',
                '-c:v', 'libx264', '-g', '50', '-pix_fmt', 'yuv420p',
                '-c:a', 'aac', video, stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL)
            self.assertEqual(await process.wait(), 0)
            try:
                url = await relay.start(video, '127.0.0.1')
                directory = Path(relay.directory.name)
                await relay.process.wait()
                async with ClientSession() as session:
                    async with session.get(url) as response:
                        self.assertEqual(response.status, 200)
                        manifest = await response.text()
                        self.assertIn('#EXTM3U', manifest)
                    segment = next(line for line in manifest.splitlines() if line.endswith('.ts'))
                    async with session.get(url.rsplit('/', 1)[0] + '/' + segment) as response:
                        self.assertEqual(response.status, 200)
                        self.assertGreater(len(await response.read()), 0)
                    bad = url.split('/')
                    bad[-2] = 'wrong-token'
                    async with session.get('/'.join(bad)) as response:
                        self.assertEqual(response.status, 403)
                self.assertLessEqual(len(list(directory.glob('*.ts'))), 8)
            finally:
                await relay.stop()
            self.assertFalse(directory.exists())


if __name__ == '__main__':
    unittest.main()
