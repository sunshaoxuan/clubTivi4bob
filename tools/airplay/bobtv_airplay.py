"""Private JSON-lines child process for BobTV. No listening control port."""
import asyncio
import contextlib
import json
import logging
import os
import re
from pathlib import Path
import sys
from urllib.parse import urlsplit

import pyatv
from pyatv.const import PairingRequirement, Protocol
from pyatv.protocols.airplay.utils import AirPlayFlags
from pyatv.storage.file_storage import FileStorage
from video_relay import VideoRelay
from egress_policy import server_or_local_url
import mac_sender
from airplay_video_v2 import normalize_features, play_video, video_v2_only
from transport_cleanup import install as install_transport_cleanup

install_transport_cleanup()


def emit(value):
    print(json.dumps(value, ensure_ascii=True), flush=True)


def stage(name):
    print(f'BobTV AirPlay stage: {name}', file=sys.stderr, flush=True)


class ReceiverUnsupportedError(Exception):
    pass


def is_native_mac(service):
    return bool(re.match(r'^(?:MacBook(?:Pro|Air)?|Macmini|MacPro|MacStudio|iMac(?:Pro)?|Mac)\d+,\d+$',
                         service.properties.get('model', ''), re.I))


def receiver_limitation(service):
    if service.properties.get('act') == '2':
        return '接收端僅允許目前使用者的 Apple 帳號。請在 Mac 的 AirPlay 接收器設定確認允許範圍；BobTV 尚未支援 Apple 帳號驗證。'
    if service.requires_password:
        return '此接收端需要固定 AirPlay 密碼，BobTV 視頻投放尚未支援。可在電視設定改用螢幕驗證碼，或直接使用 DLNA。'
    if is_native_mac(service):
        if not mac_sender.available():
            return '此安裝缺少 Mac 視頻投放組件，請更新包含 Mac AirPlay 支援的版本。'
        if service.pairing != PairingRequirement.NotNeeded:
            return 'Mac 接收器需允許所有人並關閉「需要密碼」，此模式不使用四位驗證碼。'
        return None
    if service.pairing in (PairingRequirement.Unsupported, PairingRequirement.Disabled):
        return '接收設備的配對方式目前不受支援或已停用。'
    return None


def error_message(error):
    # Protocol exceptions can contain source URLs or credentials. Do not expose them.
    kind = type(error).__name__
    if isinstance(error, ReceiverUnsupportedError):
        return str(error)
    if 'Authentication' in kind or 'Credentials' in kind or 'Pairing' in kind:
        return 'AirPlay 驗證失敗，接收端未完成配對。請取消後確認設備相容性。'
    if 'Timeout' in kind:
        return 'AirPlay 連接逾時，請確認電視已開啟投屏並在同一網路。'
    if 'NotSupported' in kind:
        return '接收設備不支援此 AirPlay 操作或視頻網址播放。'
    return f'AirPlay 操作失敗（{kind}），請確認接收設備及視頻格式。'


def video_capable(service):
    try:
        flags = normalize_features(service)
    except ValueError:
        return False
    return (AirPlayFlags.SupportsAirPlayVideoV1 in flags
            or AirPlayFlags.SupportsAirPlayVideoV2 in flags)


def validate_url(url, allow_loopback=False):
    server_or_local_url(url)
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
        self.video_session = None
        self.play_task = None
        self.generation = 0
        self.native_mac = False
        self.relay = VideoRelay()
        self.relay.on_error = lambda message: emit({'event': 'error', 'message': message})

    async def scan(self, host=None):
        stage('scan')
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
                            'unavailableReason': receiver_limitation(service),
                            'requiresPairing': not is_native_mac(service) and service.pairing == PairingRequirement.Mandatory,
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
        native_mac, self.native_mac = self.native_mac, False
        if task:
            task.cancel()
        if atv:
            close_tasks = atv.close()
            if close_tasks:
                await asyncio.wait(close_tasks, timeout=3)
        if task:
            try:
                await asyncio.wait_for(asyncio.shield(task), 15 if native_mac else 3)
            except asyncio.TimeoutError:
                if native_mac and not task.done():
                    self.play_task = task
                    self.native_mac = True
                    raise RuntimeError('Previous Mac sender is still closing') from None
            except (asyncio.CancelledError, Exception):
                pass
        await self.relay.stop()

    async def playback(self, atv, url, generation, mac_config=None, video_config=None,
                       started=None):
        def set_session(session):
            self.video_session = session

        try:
            if mac_config:
                service = mac_config.get_service(Protocol.AirPlay)
                await mac_sender.play(str(mac_config.address), service.port, url)
            elif video_config:
                service = video_config.get_service(Protocol.AirPlay)
                await play_video(video_config, service, url, started, stage, set_session)
            else:
                await atv.stream.play_url(url)
            if generation == self.generation and (started is None or started.is_set()):
                emit({'event': 'ended'})
        except asyncio.CancelledError:
            raise
        except Exception as error:
            if generation == self.generation and (started is None or started.is_set()):
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
            reason = receiver_limitation(config.get_service(Protocol.AirPlay))
            if reason:
                raise ReceiverUnsupportedError(reason)
            if is_native_mac(config.get_service(Protocol.AirPlay)):
                raise ReceiverUnsupportedError('此 Mac 使用免驗證碼連線，請直接選擇投放。')
            self.pairing = await pyatv.pair(config, Protocol.AirPlay,
                                          asyncio.get_running_loop(), storage=self.storage,
                                          name='BobTV')
            try:
                stage('pin-challenge')
                await self.pairing.begin()
            except BaseException:
                await self.cancel_pair()
                raise
            return {'deviceProvidesPin': self.pairing.device_provides_pin}
        if action == 'pair_finish':
            if not self.pairing:
                raise ValueError('No pairing session')
            pin = str(command['pin'])
            if not pin.isascii() or not pin.isdigit() or len(pin) != 4:
                raise ValueError('Invalid PIN')
            try:
                stage('pin-verification')
                self.pairing.pin(pin)
                await self.pairing.finish()
                if not self.pairing.has_paired:
                    raise pyatv.exceptions.PairingError('Pairing incomplete')
                await self.storage.save()
                stage('credentials-saved')
            finally:
                await self.cancel_pair()
            return {'paired': True}
        if action == 'play':
            use_relay = command.get('relay', False)
            config = self.configs[command['device']]
            service = config.get_service(Protocol.AirPlay)
            native_mac = is_native_mac(service)
            url = validate_url(command['url'], allow_loopback=use_relay or native_mac)
            reason = receiver_limitation(service)
            if reason:
                raise ReceiverUnsupportedError(reason)
            video_v2 = not native_mac and video_v2_only(service)
            await self.stop()
            self.native_mac = native_mac
            try:
                if use_relay and not native_mac:
                    stage('relay-start')
                    url = await self.relay.start(url, config.address)
                if video_v2:
                    settings = await self.storage.get_settings(config)
                    config.apply(settings)
                    stage('credentials-reused' if service.credentials else 'no-saved-credentials')
                elif not native_mac:
                    stage('receiver-connect')
                    self.atv = await pyatv.connect(config, asyncio.get_running_loop(), storage=self.storage)
                started = asyncio.Event() if video_v2 else None
                self.play_task = asyncio.create_task(self.playback(
                    self.atv, url, self.generation, config if native_mac else None,
                    config if video_v2 else None, started))
                self.play_task.add_done_callback(
                    lambda task: task.exception() if not task.cancelled() else None)
                if started is not None:
                    # A successful RTSP response only queued the media. Wait
                    # for the receiver's playing event or the underlying error.
                    ready = asyncio.create_task(started.wait())
                    try:
                        done, _ = await asyncio.wait(
                            [self.play_task, ready], timeout=17,
                            return_when=asyncio.FIRST_COMPLETED)
                        if self.play_task in done:
                            await self.play_task
                            raise RuntimeError('Playback ended before startup')
                        if ready not in done:
                            raise asyncio.TimeoutError()
                    finally:
                        ready.cancel()
                        await asyncio.gather(ready, return_exceptions=True)
                    return {'status': 'playing'}
                # Legacy pyatv and the Mac frame sender have no start event.
                done, _ = await asyncio.wait([self.play_task], timeout=1)
                if done:
                    await self.play_task
                    raise RuntimeError('Playback ended before startup')
                return {'status': 'sent'}
            except BaseException:
                await self.stop()
                raise
        if action == 'stop':
            await self.stop()
            return {}
        if action in ('pause', 'resume', 'volume'):
            if self.native_mac:
                raise ReceiverUnsupportedError('Mac 投放的暫停與音量控制尚未啟用，請在 Mac 上調整音量；可隨時停止投放。')
            if self.video_session:
                if action == 'volume':
                    raise ReceiverUnsupportedError('請使用電視遙控器調整 AirPlay 音量。')
                await self.video_session.send({'type': 'setRate',
                                               'rate': 0.0 if action == 'pause' else 1.0})
                return {}
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
    if sys.platform == 'darwin':
        base = Path.home() / 'Library' / 'Application Support' / 'BobTV' / 'AirPlay'
    else:
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
