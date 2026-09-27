"""Developer-only decoder/backpressure/cleanup check. Does not cast anything."""
import asyncio
import json
from mac_source import FFmpegFrames


async def main():
    source = FFmpegFrames('C:\\ProgramData\\chocolatey\\lib\\ffmpeg\\tools\\ffmpeg\\bin\\ffmpeg.exe', test=True)
    counts = {'video': 0, 'audio': 0}
    async def consume_video():
        async for config, nals in source.video():
            counts['video'] += 1
            await asyncio.sleep(.04)
    async def consume_audio():
        async for pcm in source.audio():
            counts['audio'] += 1
            await asyncio.sleep(352 / 44100)
    tasks = []
    try:
        await source.start()
        tasks = [asyncio.create_task(consume_video()), asyncio.create_task(consume_audio())]
        await asyncio.sleep(12)
        for task in tasks:
            if task.done():
                await task
        print(json.dumps({'stage': 'decoder', 'counts': counts,
                          'audioConnected': source.audio_reader is not None,
                          'testOnlyErrors': source.test_error_tail.decode(errors='replace'),
                          'retainedVideoBytes': len(source.parser.buffer) + source.parser.frame_bytes}), flush=True)
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        process = source.process
        await source.close()
        print(json.dumps({'stage': 'decoder-cleanup', 'processExited': process is None or process.returncode is not None}), flush=True)
