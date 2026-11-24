import asyncio
from ipaddress import IPv4Address
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock, patch

from pyatv.auth.hap_pairing import TRANSIENT_CREDENTIALS
from pyatv.auth.hap_session import HAPSession
from pyatv.conf import AppleTV, ManualService
from pyatv.const import PairingRequirement, Protocol
from pyatv.exceptions import PairingError, PlaybackError, ProtocolError
from pyatv.storage.file_storage import FileStorage
from pyatv.support.http import parse_request

from bobtv_airplay import Bridge, ReceiverUnsupportedError
from airplay_video_v2 import queue_item, video_v2_only


def binary(value):
    return plistlib.dumps(value, fmt=plistlib.FMT_BINARY)


class VideoV2Tests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.commands = []
        self.feedback = asyncio.Event()
        self.event_connected = asyncio.Event()
        self.events_closed = asyncio.Event()
        self.control_closed = asyncio.Event()
        self.writer = None
        self.reject = False
        self.fail_media = False
        self.playing_delay = None
        self.queue_received = asyncio.Event()
        self.acknowledged = asyncio.Event()
        self.output_key = bytes(range(32))
        self.input_key = bytes(reversed(range(32)))
        self.event_crypto = HAPSession()
        self.event_crypto.enable(self.input_key, self.output_key)
        event_server = await asyncio.start_server(self.events, '127.0.0.1', 0)
        self.event_port = event_server.sockets[0].getsockname()[1]
        control = await asyncio.start_server(self.control, '127.0.0.1', 0)
        self.port = control.sockets[0].getsockname()[1]
        self.addCleanup(event_server.close)
        self.addCleanup(control.close)

        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path = str(Path(temp.name) / 'pairings.json')
        storage = FileStorage(self.path, asyncio.get_running_loop())
        await storage.load()
        self.bridge = Bridge(storage)
        self.addAsyncCleanup(self.bridge.stop)
        self.config = self.device()
        self.bridge.configs['tv'] = self.config
        verifier = Mock()
        verifier.encryption_keys.return_value = (self.output_key, self.input_key)
        # Exercise real RTSP and HAP event framing with fixture keys. Pair-Verify
        # itself is delegated to the pinned library and stubbed for this peer.
        patcher = patch('pyatv.protocols.raop.protocols.airplayv2.verify_connection',
                        AsyncMock(return_value=verifier))
        self.verify = patcher.start()
        self.addCleanup(patcher.stop)
        self.play = {'action': 'play', 'device': 'tv', 'relay': True,
                     'url': 'http://127.0.0.1/fixture'}
        self.bridge.relay.start = AsyncMock(return_value='http://127.0.0.1/live.m3u8?channel=1')
        self.bridge.relay.stop = AsyncMock()

    def device(self, password=False):
        config = AppleTV(IPv4Address('127.0.0.1'), 'LG fixture')
        config.add_service(ManualService(
            'tv', Protocol.AirPlay, self.port,
            {'features': '0x7F8AD0,0xB8BCF46', 'deviceid': 'AA:BB:CC:DD:EE:01'},
            requires_password=password, pairing_requirement=PairingRequirement.Mandatory))
        return config

    async def events(self, reader, writer):
        self.writer = writer
        self.event_connected.set()
        try:
            while data := await reader.read(4096):
                if b'200 OK' in self.event_crypto.decrypt(data):
                    self.acknowledged.set()
        finally:
            writer.close()
            self.events_closed.set()

    async def send_event(self, message):
        await self.event_connected.wait()
        body = binary({'params': {'data': binary(message)}})
        request = f'POST /command RTSP/1.0\r\nCSeq: 1\r\nContent-Length: {len(body)}\r\n\r\n'.encode() + body
        self.writer.write(self.event_crypto.encrypt(request))
        await self.writer.drain()

    async def control(self, reader, writer):
        pending = b''
        try:
            while data := await reader.read(4096):
                pending += data
                while pending:
                    request, next_data = parse_request(pending)
                    if request is None:
                        break
                    pending = next_data
                    code = 200
                    body = b''
                    queue_complete = False
                    if request.method == 'SETUP':
                        args = plistlib.loads(request.body)
                        if 'streams' in args:
                            stream = args['streams'][0]
                            self.assertEqual((stream['type'], stream['controlType']), (130, 1))
                            self.assertEqual(stream['channelID'], 'AA:BB:CC:DD:EE:01-RCS-2')
                            body = binary({'streams': [{'type': 130, 'streamID': 6}]})
                        else:
                            self.assertGreater(args['timingPort'], 0)
                            body = binary({'eventPort': self.event_port})
                    elif request.path == '/feedback':
                        self.feedback.set()
                    elif request.path == '/command':
                        self.assertEqual(request.headers['X-Apple-StreamID'], '6')
                        command = plistlib.loads(plistlib.loads(request.body)['params']['data'])
                        self.commands.append(command)
                        if self.reject:
                            code = 501
                        queue_complete = command == {'type': 'setRate', 'rate': 1.0} and len(self.commands) == 3
                    else:
                        self.assertEqual(request.method, 'RECORD')
                    response = (f'RTSP/1.0 {code} Response\r\nCSeq: {request.headers["CSeq"]}\r\n'
                                f'Content-Length: {len(body)}\r\n\r\n').encode() + body
                    writer.write(response)
                    await writer.drain()
                    if queue_complete:
                        self.queue_received.set()
                        if self.playing_delay:
                            await self.playing_delay.wait()
                        if self.fail_media:
                            await self.send_event({'type': 'notification', 'name': 'itemFailedToPlayToEnd'})
                        else:
                            await self.send_event({'type': 'playbackState', 'name': 'playing'})
        finally:
            writer.close()
            self.control_closed.set()

    async def test_v2_waits_for_playing_and_closes_both_connections(self):
        self.playing_delay = asyncio.Event()
        pending = asyncio.create_task(self.bridge.command(self.play))
        self.addCleanup(pending.cancel)
        self.addCleanup(self.playing_delay.set)
        await asyncio.wait_for(self.queue_received.wait(), 3)
        await asyncio.wait_for(self.feedback.wait(), 3)
        self.assertFalse(pending.done())
        self.playing_delay.set()
        self.assertEqual(await asyncio.wait_for(pending, 4), {'status': 'playing'})
        await asyncio.wait_for(self.acknowledged.wait(), 2)
        self.assertEqual([cmd['type'] for cmd in self.commands],
                         ['insertPlayQueueItem', 'setProperty', 'setRate'])
        self.assertEqual(self.commands[0]['item']['mediaType'], 'streaming')
        self.assertEqual(queue_item('https://example.test/clip.mp4')['mediaType'], 'file')
        await self.bridge.command({'action': 'pause'})
        self.assertEqual(self.commands[-1], {'type': 'setRate', 'rate': 0.0})
        await self.bridge.command({'action': 'stop'})
        await asyncio.wait_for(self.control_closed.wait(), 2)
        await asyncio.wait_for(self.events_closed.wait(), 2)
        self.assertIsNone(self.bridge.video_session)
        self.bridge.relay.stop.assert_awaited()

    async def test_v2_rejects_protocol_failure_and_closes(self):
        self.reject = True
        with self.assertRaises(ProtocolError):
            await asyncio.wait_for(self.bridge.command(self.play), 4)
        self.assertIsNone(self.bridge.play_task)
        self.assertIsNone(self.bridge.video_session)
        await asyncio.wait_for(self.events_closed.wait(), 2)

    async def test_v2_reports_receiver_media_failure(self):
        self.fail_media = True
        with self.assertRaises(PlaybackError):
            await asyncio.wait_for(self.bridge.command(self.play), 4)
        await asyncio.wait_for(self.control_closed.wait(), 2)
        await asyncio.wait_for(self.events_closed.wait(), 2)

    async def test_v2_late_receiver_error_stops_the_relay(self):
        with patch('bobtv_airplay.emit') as emit:
            self.assertEqual(await asyncio.wait_for(self.bridge.command(self.play), 4),
                             {'status': 'playing'})
            await self.send_event({'type': 'notification', 'name': 'itemFailedToPlayToEnd',
                                   'params': {'url': 'https://secret.test/'}})
            with self.assertRaises(PlaybackError):
                await asyncio.wait_for(self.bridge.play_task, 4)
            self.assertEqual(emit.call_args.args[0]['event'], 'error')
            self.assertNotIn('secret.test', str(emit.call_args))
        self.bridge.relay.stop.assert_awaited()
        await asyncio.wait_for(self.control_closed.wait(), 2)
        await asyncio.wait_for(self.events_closed.wait(), 2)

    async def test_pin_cancel_error_retry_save_rescan_and_reuse(self):
        self.assertTrue(video_v2_only(self.config.get_service(Protocol.AirPlay)))
        self.assertEqual(self.config.get_service(Protocol.AirPlay).properties['features'],
                         '0x007F8AD0,0xB8BCF46')
        # Use the real pyatv pairing handler and FileStorage. Stub the device's
        # PIN cryptography so this test can isolate cancellation and persistence.
        procedure = Mock()
        procedure.start_pairing = AsyncMock()
        procedure.finish_pairing = AsyncMock(side_effect=[
            PairingError('bad PIN'), TRANSIENT_CREDENTIALS])
        start = {'action': 'pair_start', 'device': 'tv'}
        with patch('pyatv.protocols.airplay.pairing.pair_setup', return_value=procedure) as setup:
            await self.bridge.command(start)
            await self.bridge.command({'action': 'pair_cancel'})
            self.assertIsNone(self.bridge.pairing)
            await self.bridge.command(start)
            with self.assertRaises(PairingError):
                await self.bridge.command({'action': 'pair_finish', 'pin': '1111'})
            self.assertFalse(Path(self.path).exists())
            self.assertIsNone(self.bridge.pairing)
            await self.bridge.command(start)
            self.assertEqual(await self.bridge.command({'action': 'pair_finish', 'pin': '0123'}),
                             {'paired': True})
            self.assertEqual(procedure.finish_pairing.await_args.args[1], '0123')
            self.assertEqual(setup.call_args.args[0].name, 'HAP')
        storage = FileStorage(self.path, asyncio.get_running_loop())
        await storage.load()
        self.bridge.storage = storage
        self.control_closed.clear()
        with patch('bobtv_airplay.pyatv.scan', AsyncMock(return_value=[self.device()])):
            result = await self.bridge.scan()
        self.assertTrue(result['devices'][0]['paired'])
        self.assertEqual(await asyncio.wait_for(self.bridge.command(self.play), 4), {'status': 'playing'})
        self.assertEqual(self.verify.await_args.args[0], TRANSIENT_CREDENTIALS)

    async def test_fixed_password_never_opens_pin_or_playback(self):
        self.bridge.configs['tv'] = self.device(password=True)
        with patch('bobtv_airplay.pyatv.pair', AsyncMock()) as pair:
            with self.assertRaisesRegex(ReceiverUnsupportedError, '固定 AirPlay 密碼'):
                await self.bridge.command({'action': 'pair_start', 'device': 'tv'})
            with self.assertRaises(ReceiverUnsupportedError):
                await self.bridge.command(self.play)
            pair.assert_not_awaited()
            self.bridge.relay.start.assert_not_awaited()
