import asyncio
import plistlib
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, Mock, patch

from mac_video import MacVideoProtocol, play_mac_url


class MacVideoTests(unittest.IsolatedAsyncioTestCase):
    def test_receiver_clock_uses_monotonic_elapsed_not_wall_clock(self):
        protocol = MacVideoProtocol(Mock(), Mock())
        protocol.clock_anchor = 1234.5
        protocol.clock_local = 100
        with patch('mac_video.time.monotonic', return_value=102):
            self.assertEqual(protocol.media_time(), 1236.5)

    async def test_video_request_uses_one_session_identity(self):
        connection = SimpleNamespace(post=AsyncMock(return_value=SimpleNamespace(code=200)),
                                     remote_ip='127.0.0.1', send_and_receive=AsyncMock())
        rtsp = SimpleNamespace(connection=connection, record=AsyncMock(), exchange=AsyncMock())
        protocol = MacVideoProtocol(Mock(), rtsp)
        protocol._setup_base = AsyncMock()
        protocol.start_feedback = AsyncMock()
        protocol.control_port = 7000
        with patch('mac_video.open_reverse', AsyncMock()):
            await protocol.play_url(1234, 'http://example.com/video')
        request = connection.post.call_args
        body = plistlib.loads(request.kwargs['body'])
        self.assertEqual(request.kwargs['headers']['X-Apple-Session-ID'], protocol.uuid)
        self.assertEqual(body['uuid'], protocol.uuid)
        self.assertEqual(body['Content-Location'], 'mlhls://localhost/master.m3u8')

    async def test_status_unavailable_is_not_playback_success_and_cancel_closes(self):
        poll = AsyncMock(return_value=SimpleNamespace(code=500, body=b''))
        connection = SimpleNamespace(local_ip='127.0.0.1',
                                     send_and_receive=poll, close=Mock())
        protocol = SimpleNamespace(play_url=AsyncMock(return_value=SimpleNamespace(code=200)),
                                   teardown=Mock(), _feedback_task=None)
        transport = Mock()
        timer = SimpleNamespace(port=12345)
        with patch('mac_video.http_connect', AsyncMock(return_value=connection)), \
             patch('mac_video.RtspSession', Mock()), \
             patch('mac_video.MacVideoProtocol', Mock(return_value=protocol)), \
             patch.object(asyncio.get_running_loop(), 'create_datagram_endpoint',
                          AsyncMock(return_value=(transport, timer))):
            task = asyncio.create_task(play_mac_url('127.0.0.1', 7000, 'http://example.com/video'))
            for _ in range(30):
                if poll.await_count:
                    break
                await asyncio.sleep(0)
            self.assertEqual(poll.await_count, 1)
            self.assertFalse(task.done())
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        transport.close.assert_called_once()
        connection.close.assert_called_once()
        protocol.teardown.assert_called_once()
        self.assertIn('X-Apple-Session-ID', poll.call_args.kwargs['headers'])

    async def test_setup_rejects_invalid_event_port(self):
        rtsp = SimpleNamespace(connection=Mock(), setup=AsyncMock(
            return_value=SimpleNamespace(body=plistlib.dumps({'eventPort': 0}))))
        protocol = MacVideoProtocol(Mock(), rtsp)
        with patch('mac_video.authenticate', AsyncMock()), \
             patch('mac_video.setup_channel', AsyncMock()) as channel:
            with self.assertRaisesRegex(ValueError, 'event port'):
                await protocol._setup_base(1234)
            channel.assert_not_awaited()


if __name__ == '__main__':
    unittest.main()
