import unittest
import asyncio
from unittest.mock import AsyncMock, Mock
from mac_source import AnnexBFrames, FFmpegFrames, PCM_BYTES


class SourceTests(unittest.TestCase):
    def test_every_fragment_boundary(self):
        nals = [b'\x67\x42\x00\x1e', b'\x68ab', b'\x09x', b'\x65abc',
                b'\x09x', b'\x41def']
        data = b''.join(b'\x00\x00\x00\x01' + n for n in nals)
        for split in range(1, len(data)):
            parser = AnnexBFrames()
            frames = parser.feed(data[:split]) + parser.feed(data[split:], final=True)
            self.assertEqual(frames, [[b'\x65abc'], [b'\x41def']], split)
            self.assertEqual(parser.config[:6], b'\x01\x42\x00\x1e\xff\xe1')

    def test_no_delimiter_is_bounded(self):
        parser = AnnexBFrames(max_bytes=16)
        parser.feed(b'x' * 12)
        with self.assertRaises(ValueError):
            parser.feed(b'x' * 12)

    def test_long_broadcast_does_not_accumulate(self):
        parser = AnnexBFrames()
        for _ in range(10000):
            parser.feed(b'\x00\x00\x01\x09x\x00\x00\x01\x41abc')
        self.assertLess(len(parser.buffer), 16)
        self.assertLess(parser.frame_bytes, 16)


class SourceAsyncTests(unittest.IsolatedAsyncioTestCase):
    async def test_audio_reads_without_waiting_for_its_own_connection_to_close(self):
        source = FFmpegFrames('unused', test=True)
        source.connected = asyncio.get_running_loop().create_future()
        source.connected.set_result(None)
        source.audio_reader = Mock(readexactly=AsyncMock(return_value=bytes(PCM_BYTES)))
        source.server = Mock(wait_closed=AsyncMock())
        iterator = source.audio()
        self.assertEqual(await asyncio.wait_for(iterator.__anext__(), .5), bytes(PCM_BYTES))
        source.server.close.assert_called_once()
        source.server.wait_closed.assert_not_awaited()
        await iterator.aclose()
