"""Private JSON-lines child process for BobTV. No listening control port."""
import asyncio
import contextlib
import json
import logging
import os
import re
from pathlib import Path
import sys
import time
import math
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
from cast_diagnostics import record, failure_details, record_network, request_id
from mac_auth import MacPinPairing, MacPasswordPairing, MacAuthenticationError
from pyatv.support.http import http_connect

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
    if service.requires_password and not is_native_mac(service):
        return '此接收端需要固定 AirPlay 密碼，BobTV 視頻投放尚未支援。可在電視設定改用螢幕驗證碼，或直接使用 DLNA。'
    if is_native_mac(service):
        if not mac_sender.available():
            return '此安裝缺少 Mac 視頻投放組件，請更新包含 Mac AirPlay 支援的版本。'
        return None
    if service.pairing in (PairingRequirement.Unsupported, PairingRequirement.Disabled):
        return '接收設備的配對方式目前不受支援或已停用。'
    return None


def error_message(error):
    # Protocol exceptions can contain source URLs or credentials. Do not expose them.
    kind = type(error).__name__
    if isinstance(error, ReceiverUnsupportedError):
        return str(error)
    if isinstance(error, MacAuthenticationError):
        if error.reason in {'receiver-error-3', 'receiver-error-5', 'receiver-error-7', 'backoff-active'}:
            return f'Mac 接收端暫停了認證嘗試，請在 {error.retry_after or 60} 秒後再試。'
        if error.reason == 'receiver-error-2':
            return '驗證碼或接收密碼未通過驗證，請確認所選認證方式並重新輸入。'
        if error.reason == 'receiver-error-4':
            return '接收端已達到配對設備數量上限。'
        if error.reason == 'timeout':
            return f'等待 Mac 認證回應逾時（{error.stage}）。'
        return f'Mac 認證未完成（{error.stage}：{error.reason}）。'
    if isinstance(error, FileNotFoundError):
        return '此安裝缺少 AirPlay 本地轉封裝組件，請更新完整安裝包。'
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
        self.pairing_device = None
        # Password-derived verified identities live only in process memory.
        # Receiver passwords themselves are discarded after the HAP exchange.
        self.mac_password_credentials = {}
        self.auth_block_until = {}
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
            native = is_native_mac(service)
            mode = 'password' if service.requires_password else 'pin'
            if native:
                paired = paired or key in self.mac_password_credentials
            devices.append({'id': key, 'name': config.name,
                            'address': str(config.address), 'paired': paired,
                            'unavailableReason': receiver_limitation(service),
                            'requiresPairing': (service.requires_password or
                                service.pairing != PairingRequirement.NotNeeded) if native else
                                service.pairing == PairingRequirement.Mandatory,
                            'authenticationMode': mode,
                            'nativeMac': native,
                            'passwordRequired': service.requires_password})
        return {'devices': devices}

    async def cancel_pair(self):
        if self.pairing:
            pairing, self.pairing = self.pairing, None
            self.pairing_device = None
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
                       started=None, mac_credentials=None, mac_password=None):
        def set_session(session):
            self.video_session = session

        try:
            if mac_config:
                service = mac_config.get_service(Protocol.AirPlay)
                def native_progress(item):
                    if started is not None and item.get('stage') == 'frame-progress' and item.get('count', 0) > 0:
                        started.set()
                await mac_sender.play(str(mac_config.address), service.port, url,
                    on_progress=native_progress,
                    credentials=mac_credentials, password=mac_password)
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
            details = failure_details(error)
            record({'stage': 'playback-failed', **details})
            if generation == self.generation and (started is None or started.is_set()):
                emit({'event': 'error', 'message': error_message(error),
                      'requestId': request_id.get(), **details})
            raise
        finally:
            if generation == self.generation:
                await self.relay.stop()

    async def command(self, command):
        action = command['action']
        if action == 'scan':
            return await self.scan(command.get('host'))
        if action == 'pair_cancel':
            record({'stage': 'auth-cancelled', 'authResult': 'cancelled'})
            await self.cancel_pair()
            return {}
        if action == 'pair_start':
            await self.cancel_pair()
            config = self.configs[command['device']]
            asyncio.create_task(asyncio.to_thread(record_network, config.address,
                config.get_service(Protocol.AirPlay).port))
            reason = receiver_limitation(config.get_service(Protocol.AirPlay))
            if reason:
                raise ReceiverUnsupportedError(reason)
            service = config.get_service(Protocol.AirPlay)
            remaining = self.auth_block_until.get(command['device'], 0) - time.monotonic()
            if remaining > 0:
                raise MacAuthenticationError('M1', 'backoff-active', retry_after=math.ceil(remaining),
                    mode=command.get('mode', 'pin'))
            if is_native_mac(service):
                mode = command.get('mode', 'password' if service.requires_password else 'pin')
                if mode not in {'pin', 'password'}:
                    raise ValueError('Invalid authentication mode')
                connection = await asyncio.wait_for(http_connect(str(config.address), service.port), 8)
                self.pairing = (MacPasswordPairing(connection) if mode == 'password'
                                else MacPinPairing(connection))
                self.pairing_device = command['device']
            else:
                self.pairing = await pyatv.pair(config, Protocol.AirPlay,
                                          asyncio.get_running_loop(), storage=self.storage,
                                          name='BobTV')
            try:
                stage('pin-challenge')
                await self.pairing.begin()
            except BaseException as error:
                self.remember_backoff(command['device'], error)
                await self.cancel_pair()
                raise
            return {'deviceProvidesPin': self.pairing.device_provides_pin,
                    'authenticationMode': 'password' if isinstance(self.pairing, MacPasswordPairing) else 'pin'}
        if action == 'pair_finish':
            if not self.pairing:
                raise ValueError('No pairing session')
            secret = command.get('password') if isinstance(self.pairing, MacPasswordPairing) else command.get('pin')
            if not isinstance(secret, str) or not 1 <= len(secret.encode('utf-8')) <= 256:
                raise ValueError('Invalid secret')
            if not isinstance(self.pairing, MacPasswordPairing) and (
                    not secret.isascii() or not secret.isdigit() or len(secret) != 4):
                raise ValueError('Invalid PIN')
            pairing_device = self.pairing_device
            try:
                stage('secret-verification')
                if isinstance(self.pairing, (MacPinPairing, MacPasswordPairing)):
                    await self.pairing.finish(secret)
                    if not self.pairing.has_paired:
                        raise pyatv.exceptions.PairingError('Pairing incomplete')
                    if isinstance(self.pairing, MacPasswordPairing):
                        self.mac_password_credentials[self.pairing_device] = str(self.pairing.credentials)
                    else:
                        self.mac_password_credentials.pop(self.pairing_device, None)
                        config = self.configs[self.pairing_device]
                        settings = await self.storage.get_settings(config)
                        settings.protocols.airplay.credentials = str(self.pairing.credentials)
                        config.get_service(Protocol.AirPlay).credentials = str(self.pairing.credentials)
                else:
                    self.pairing.pin(secret)
                    await self.pairing.finish()
                if not self.pairing.has_paired:
                    raise pyatv.exceptions.PairingError('Pairing incomplete')
                if not isinstance(self.pairing, MacPasswordPairing):
                    await self.storage.save()
                    stage('credentials-saved')
            except BaseException as error:
                self.remember_backoff(pairing_device, error)
                raise
            finally:
                await self.cancel_pair()
            return {'paired': True}
        if action == 'play':
            use_relay = command.get('relay', False)
            config = self.configs[command['device']]
            asyncio.create_task(asyncio.to_thread(record_network, config.address,
                config.get_service(Protocol.AirPlay).port))
            service = config.get_service(Protocol.AirPlay)
            record({'stage': 'receiver-capabilities',
                    'receiverModel': service.properties.get('model', ''),
                    'receiverFeatures': service.properties.get('features', ''),
                    'passwordRequired': service.requires_password})
            native_mac = is_native_mac(service)
            mac_credentials = mac_password = None
            if native_mac:
                settings = await self.storage.get_settings(config)
                config.apply(settings)
                mac_credentials = self.mac_password_credentials.get(command['device']) or service.credentials
                if service.requires_password and not mac_credentials:
                    raise ReceiverUnsupportedError('請先輸入此 Mac 的 AirPlay 接收密碼。')
                if (not service.requires_password and
                    service.pairing != PairingRequirement.NotNeeded and not mac_credentials):
                    raise ReceiverUnsupportedError('請先選擇 Mac 的驗證碼或接收密碼，完成認證。')
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
                    record({'stage': 'receiver-credential-state',
                            'savedCredentialsAvailable': bool(service.credentials)})
                    stage('credentials-reused' if service.credentials else 'no-saved-credentials')
                elif not native_mac:
                    stage('receiver-connect')
                    self.atv = await pyatv.connect(config, asyncio.get_running_loop(), storage=self.storage)
                started = asyncio.Event() if video_v2 or native_mac else None
                self.play_task = asyncio.create_task(self.playback(
                    self.atv, url, self.generation, config if native_mac else None,
                    config if video_v2 else None, started,
                    mac_credentials=mac_credentials, mac_password=mac_password))
                self.play_task.add_done_callback(
                    lambda task: task.exception() if not task.cancelled() else None)
                if started is not None:
                    # A successful RTSP response only queued the media. Wait
                    # for the receiver's playing event or the underlying error.
                    ready = asyncio.create_task(started.wait())
                    try:
                        done, _ = await asyncio.wait(
                            [self.play_task, ready], timeout=50 if native_mac else 17,
                            return_when=asyncio.FIRST_COMPLETED)
                        if self.play_task in done:
                            await self.play_task
                            raise RuntimeError('Playback ended before startup')
                        if ready not in done:
                            raise asyncio.TimeoutError()
                    finally:
                        ready.cancel()
                        await asyncio.gather(ready, return_exceptions=True)
                    return {'status': 'streaming' if native_mac else 'playing'}
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

    def remember_backoff(self, device, error):
        if device and isinstance(error, MacAuthenticationError) and (
            error.tlv_error in {3, 5, 7} or error.retry_after):
            self.auth_block_until[device] = time.monotonic() + max(1, error.retry_after or 60)


async def serve_command(bridge, request):
    trace = request.get('requestId')
    token = request_id.set(trace if isinstance(trace, str) and re.fullmatch('[a-f0-9]{32}', trace) else None)
    try:
        result = await asyncio.wait_for(bridge.command(request),
            timeout=60 if request.get('action') == 'play' else 25)
        emit({'id': request['id'], 'result': result})
    except asyncio.CancelledError:
        record({'stage': 'auth-cancelled', 'authResult': 'cancelled', 'errorCode': 'cancelled'})
        emit({'id': request.get('id'), 'error': 'AirPlay 配對已取消。',
              'errorType': 'CancelledError', 'errorCode': 'cancelled'})
    except Exception as error:
        details = failure_details(error)
        record({'stage': 'command-failed', **details})
        emit({'id': request.get('id'), 'error': error_message(error), **details})
    finally:
        request_id.reset(token)


async def main():
    from importlib.metadata import version
    record({'stage': 'helper-environment',
            'pythonVersion': '.'.join(str(x) for x in sys.version_info[:3]),
            'pyatvVersion': version('pyatv')})
    # Credentials stay in the user's profile and never enter the release bundle.
    if sys.platform == 'darwin':
        base = Path.home() / 'Library' / 'Application Support' / 'BobTV' / 'AirPlay'
    else:
        base = Path(os.environ.get('LOCALAPPDATA', str(Path.home()))) / 'BobTV' / 'AirPlay'
    base.mkdir(parents=True, exist_ok=True)
    storage = FileStorage(str(base / 'pairings.json'), asyncio.get_running_loop())
    await storage.load()
    bridge = Bridge(storage)
    auth_tasks = set()
    try:
        while True:
            line = await asyncio.to_thread(sys.stdin.readline)
            if not line:
                break
            request = {}
            try:
                request = json.loads(line)
                auth_tasks.difference_update(task for task in list(auth_tasks) if task.done())
                if request.get('action') in {'pair_cancel', 'stop'}:
                    for task in auth_tasks:
                        task.cancel()
                    await asyncio.gather(*auth_tasks, return_exceptions=True)
                    auth_tasks.clear()
                    await bridge.cancel_pair()
                if request.get('action') in {'pair_start', 'pair_finish'}:
                    if auth_tasks:
                        emit({'id': request.get('id'), 'error': 'AirPlay 配對操作正在進行。',
                              'errorCode': 'server_busy', 'errorType': 'PairingBusy'})
                    else:
                        task = asyncio.create_task(serve_command(bridge, request))
                        auth_tasks.add(task)
                        task.add_done_callback(auth_tasks.discard)
                else:
                    await serve_command(bridge, request)
            except Exception as error:
                details = failure_details(error)
                record({'stage': 'command-failed', **details})
                emit({'id': request.get('id'), 'error': error_message(error), **details})
    finally:
        for task in auth_tasks:
            task.cancel()
        await asyncio.gather(*auth_tasks, return_exceptions=True)
        await bridge.cancel_pair()
        await bridge.stop()


if __name__ == '__main__':
    logging.disable(logging.CRITICAL)
    asyncio.run(main())
