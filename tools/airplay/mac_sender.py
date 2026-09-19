"""Native-Mac video sender, independent of the Apple TV URL transport."""
import asyncio
from pathlib import Path
import sys

from mac_frames import play_test_frames
from mac_source import FFmpegFrames
from video_relay import VideoRelay


def authentication_helper():
    return Path(sys.executable).parent / 'fpsap-auth.exe'


def available():
    return authentication_helper().is_file() and bool(VideoRelay.ffmpeg_path())


async def play(address, port, url, on_progress=None):
    helper = authentication_helper()
    executable = VideoRelay.ffmpeg_path()
    if not helper.is_file() or not executable:
        raise FileNotFoundError('Native Mac sender components are missing')
    source = FFmpegFrames(executable, url)
    try:
        await source.start()
        def diagnostic(item):
            if on_progress and item.get('stage') == 'frame-progress':
                on_progress(item)
        await play_test_frames(address, port, None, str(helper), diagnostic, source=source)
    finally:
        # Finish bounded cleanup even if the caller cancels during shutdown.
        cleanup = asyncio.create_task(source.close())
        try:
            await asyncio.shield(cleanup)
        except asyncio.CancelledError:
            await cleanup
            raise
