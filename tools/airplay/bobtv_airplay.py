"""Private JSON-lines child process for BobTV. No listening control port."""
import asyncio
import contextlib
import json
import logging
import os
from pathlib import Path
import sys
from urllib.parse import urlsplit

import pyatv
from pyatv.const import PairingRequirement, Protocol
from pyatv.protocols.airplay.utils import AirPlayFlags, parse_features
from pyatv.storage.file_storage import FileStorage
from video_relay import VideoRelay


def emit(value):
    print(json.dumps(value, ensure_ascii=True), flush=True)


def error_message(error):
    # Protocol exceptions can contain source URLs or credentials. Do not expose them.
    kind = type(error).__name__
    if 'Authentication' in kind or 'Credentials' in kind or 'Pairing' in kind:
        return 'AirPlay 驗證失敗，請重新配對並確認電視上的驗證碼。'
    if 'Timeout' in kind:
        return 'AirPlay 連接逾時，請確認電視已開啟投屏並在同一網路。'
    if 'NotSupported' in kind:
        return '接收設備不支援此 AirPlay 操作或視頻網址播放。'
    return f'AirPlay 操作失敗（{kind}），請確認接收設備及視頻格式。'


def video_capable(service):
    try:
        raw = service.properties.get('features', '0x0')
        # pyatv concatenates the words; pad a short lower word to retain bit 49.
        words = raw.split(',')
        if len(words) == 2:
            raw = f'0x{int(words[0], 16):08x},0x{int(words[1], 16):x}'
        flags = parse_features(raw)
    except ValueError:
        return False
    return (AirPlayFlags.SupportsAirPlayVideoV1 in flags
            or AirPlayFlags.SupportsAirPlayVideoV2 in flags)


def validate_url(url, allow_loopback=False):
    parsed = urlsplit(url)
    if parsed.scheme not in ('http', 'https') or not parsed.hostname:
        raise ValueError('Only HTTP(S) video URLs are supported')
    if not allow_loopback and parsed.hostname.lower() in ('localhost', '127.0.0.1', '::1'):
        raise ValueError('Receiver cannot access a loopback URL')
    return url


class Bridge:
    def __init__(self, storage):
        self.storage = storage
        self.configs = {}
        self.pairing = None
        self.atv = None
        self.play_task = None
        self.generation = 0
        self.relay = VideoRelay()
        self.relay.on_error = lambda message: emit({'event': 'error', 'message': message})

    async def scan(self, host=None):
        configs = await pyatv.scan(asyncio.get_running_loop(), timeout=6,
                                  hosts=[host] if host else None,
                                  protocol=Protocol.AirPlay, storage=self.storage)
        devices = []
        for config in configs:
            service = config.get_service(Protocol.AirPlay)
            if service is None or not video_capable(service):
                continue
            key = config.identifier or str(config.address)
            self.configs[key] = config
            settings = await self.storage.get_settings(config)
            paired = bool(settings.protocols.airplay.credentials)
            devices.append({'id': key, 'name': config.name,
                            'address': str(config.address), 'paired': paired,
                            'requiresPairing': service.pairing == PairingRequirement.Mandatory,
                            'passwordRequired': service.requires_password})
        return {'devices': devices}

    async def cancel_pair(self):
        if self.pairing:
            pairing, self.pairing = self.pairing, None
            await pairing.close()

    async def stop(self):
        self.generation += 1
        task, self.play_task = self.play_task, None
        atv, self.atv = self.atv, None
        if task:
            task.cancel()
        if atv:
            close_tasks = atv.close()
            if close_tasks:
                await asyncio.wait(close_tasks, timeout=3)
        if task:
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await asyncio.wait_for(task, 3)
        await self.relay.stop()

    async def playback(self, atv, url, generation):
        try:
            await atv.stream.play_url(url)
            if generation == self.generation:
                emit({'event': 'ended'})
        except asyncio.CancelledError:
            raise
        except Exception as error:
            if generation == self.generation:
                emit({'event': 'error', 'message': error_message(error)})
            raise
        finally:
            if generation == self.generation:
                await self.relay.stop()

    async def command(self, command):
        action = command['action']
        if action == 'scan':
            return await self.scan(command.get('host'))
        if action == 'pair_cancel':
            await self.cancel_pair()
            return {}
        if action == 'pair_start':
            await self.cancel_pair()
            config = self.configs[command['device']]
            self.pairing = await pyatv.pair(config, Protocol.AirPlay,
                                          asyncio.get_running_loop(), storage=self.storage,
                                          name='BobTV')
            await self.pairing.begin()
            return {'deviceProvidesPin': self.pairing.device_provides_pin}
        if action == 'pair_finish':
            if not self.pairing:
                raise ValueError('No pairing session')
            pin = str(command['pin'])
            if not pin.isascii() or not pin.isdigit() or len(pin) != 4:
                raise ValueError('Invalid PIN')
            try:
                self.pairing.pin(pin)
                await self.pairing.finish()
                if not self.pairing.has_paired:
                    raise pyatv.exceptions.PairingError('Pairing incomplete')
                await self.storage.save()
            finally:
                await self.cancel_pair()
            return {'paired': True}
        if action == 'play':
            use_relay = command.get('relay', False)
            url = validate_url(command['url'], allow_loopback=use_relay)
            config = self.configs[command['device']]
            if config.get_service(Protocol.AirPlay).requires_password:
                raise pyatv.exceptions.NotSupportedError('Password protected receiver')
            await self.stop()
            try:
                if use_relay:
                    url = await self.relay.start(url, config.address)
                self.atv = await pyatv.connect(config, asyncio.get_running_loop(), storage=self.storage)
            except BaseException:
                await self.stop()
                raise
            self.play_task = asyncio.create_task(self.playback(self.atv, url, self.generation))
            # play_url remains active for the entire stream. Only acknowledge dispatch.
            done, _ = await asyncio.wait([self.play_task], timeout=1)
            if done:
                await self.play_task
                raise RuntimeError('Playback ended before startup')
            self.play_task.add_done_callback(
                lambda task: task.exception() if not task.cancelled() else None)
            return {'status': 'sent'}
        if action == 'stop':
            await self.stop()
            return {}
        if action in ('pause', 'resume', 'volume'):
            if not self.atv:
                raise RuntimeError('No active receiver')
            if action == 'pause':
                await self.atv.remote_control.pause()
            elif action == 'resume':
                await self.atv.remote_control.play()
            else:
                await self.atv.audio.set_volume(max(0, min(100, command['volume'])))
            return {}
        raise ValueError('Unknown command')


async def main():
    # Credentials stay in the user's profile and never enter the release bundle.
    base = Path(os.environ.get('LOCALAPPDATA', str(Path.home()))) / 'BobTV' / 'AirPlay'
    base.mkdir(parents=True, exist_ok=True)
    storage = FileStorage(str(base / 'pairings.json'), asyncio.get_running_loop())
    await storage.load()
    bridge = Bridge(storage)
    try:
        while True:
            line = await asyncio.to_thread(sys.stdin.readline)
            if not line:
                break
            request = {}
            try:
                request = json.loads(line)
                result = await asyncio.wait_for(bridge.command(request), timeout=25)
                emit({'id': request['id'], 'result': result})
            except Exception as error:
                emit({'id': request.get('id'), 'error': error_message(error)})
    finally:
        await bridge.cancel_pair()
        await bridge.stop()


if __name__ == '__main__':
    logging.disable(logging.CRITICAL)
    asyncio.run(main())
