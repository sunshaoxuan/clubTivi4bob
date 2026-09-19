import asyncio
from ipaddress import IPv4Address
import plistlib
import unittest
from unittest.mock import AsyncMock, patch

from aiohttp import web
from pyatv.conf import AppleTV, ManualService
from pyatv.const import Protocol, PairingRequirement
from pyatv.storage.memory_storage import MemoryStorage

from bobtv_airplay import Bridge, error_message, validate_url, video_capable, receiver_limitation, ReceiverUnsupportedError


class BridgeTests(unittest.IsolatedAsyncioTestCase):
    async def test_mac_receiver_never_starts_pin_exchange(self):
        service = self.bridge.configs['test-tv'].get_service(Protocol.AirPlay)
        service.properties['model'] = 'MacBookPro16,2'
        with patch('bobtv_airplay.pyatv.pair', new_callable=AsyncMock) as pair:
            with self.assertRaises(ReceiverUnsupportedError):
                await self.bridge.command({'action': 'pair_start', 'device': 'test-tv'})
            pair.assert_not_awaited()
        with self.assertRaises(ReceiverUnsupportedError):
            await self.bridge.command({'action': 'play', 'device': 'test-tv', 'url': 'https://example.com/live'})

    def test_mac_model_families_and_apple_tv(self):
        for model in ('MacBookPro16,2', 'Mac14,2', 'Macmini9,1', 'iMac20,1', 'MacBookAir10,1'):
            service = ManualService('x', Protocol.AirPlay, 7000, {'model': model})
            self.assertIn('Mac', receiver_limitation(service))
        self.assertIsNone(receiver_limitation(ManualService('x', Protocol.AirPlay, 7000, {'model': 'AppleTV6,2'}, pairing_requirement=PairingRequirement.NotNeeded)))
    async def asyncSetUp(self):
        self.urls = []
        app = web.Application()

        async def play(request):
            self.urls.append(plistlib.loads(await request.read())['Content-Location'])
            return web.Response()

        async def info(request):
            return web.Response(body=plistlib.dumps({'duration': 3600.0, 'position': 1.0}),
                                content_type='text/x-apple-plist+xml')

        app.router.add_post('/play', play)
        app.router.add_get('/playback-info', info)
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        site = web.TCPSite(self.runner, '127.0.0.1', 0)
        await site.start()
        port = site._server.sockets[0].getsockname()[1]
        config = AppleTV(IPv4Address('127.0.0.1'), 'Test television')
        config.add_service(ManualService('test-tv', Protocol.AirPlay, port,
                                        {'features': '0x1', 'model': 'AppleTV2,1'}, pairing_requirement=PairingRequirement.NotNeeded))
        self.bridge = Bridge(MemoryStorage())
        self.bridge.configs['test-tv'] = config

    async def asyncTearDown(self):
        await self.bridge.stop()
        await self.runner.cleanup()

    async def test_real_airplay_http_and_channel_switch(self):
        result = await self.bridge.command({'action': 'play', 'device': 'test-tv',
                                           'url': 'https://example.com/one.m3u8'})
        self.assertEqual(result['status'], 'sent')
        first_task = self.bridge.play_task
        await self.bridge.command({'action': 'play', 'device': 'test-tv',
                                  'url': 'https://example.com/two.m3u8'})
        self.assertTrue(first_task.done())
        self.assertEqual(self.urls, ['https://example.com/one.m3u8', 'https://example.com/two.m3u8'])
        await self.bridge.command({'action': 'stop'})
        self.assertIsNone(self.bridge.atv)
        self.assertIsNone(self.bridge.play_task)

    async def test_pairing_saved_only_after_success_and_closed(self):
        pairing = AsyncMock()
        pairing.pin = unittest.mock.Mock()
        pairing.has_paired = True
        self.bridge.pairing = pairing
        self.bridge.storage.save = AsyncMock()
        await self.bridge.command({'action': 'pair_finish', 'pin': '0123'})
        pairing.pin.assert_called_once_with('0123')
        self.bridge.storage.save.assert_awaited_once()
        pairing.close.assert_awaited_once()

    async def test_invalid_pin_does_not_send(self):
        pairing = AsyncMock()
        self.bridge.pairing = pairing
        with self.assertRaises(ValueError):
            await self.bridge.command({'action': 'pair_finish', 'pin': 'abcd'})
        pairing.finish.assert_not_awaited()
        await self.bridge.cancel_pair()

    def test_filter_speakers_and_mirror_only(self):
        def service(flags):
            return ManualService('x', Protocol.AirPlay, 7000, {'features': flags})
        self.assertTrue(video_capable(service('0x1')))
        self.assertTrue(video_capable(service('0x0,0x20000')))
        self.assertFalse(video_capable(service('0x200')))
        self.assertFalse(video_capable(service('0x80')))

    def test_reject_local_files_and_loopback(self):
        for url in ('file:///secret', 'C:\\secret', 'http://127.0.0.1/video', 'http://[::1]/video'):
            with self.assertRaises(ValueError):
                validate_url(url)

    def test_errors_do_not_disclose_urls_or_keys(self):
        message = error_message(RuntimeError('https://secret/?token=PRIVATE'))
        self.assertNotIn('PRIVATE', message)
        self.assertNotIn('secret', message)


if __name__ == '__main__':
    unittest.main()
