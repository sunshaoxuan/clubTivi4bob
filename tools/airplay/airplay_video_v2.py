"""Video URL playback for v2-only receivers with pinned pyatv 0.18.0.

Protocol reference: pyatv PR #2941, revision 90c0f9d6373c48ab98e2608544b69c10b729c643.
Feature word correction: PR #2942, revision 41bb1ee3cc1b80ddd9b88843dd24fca74268c6f8.
The upstream changes are MIT licensed. This adapter uses the installed pyatv
session setup and leaves the upstream v1, RAOP and native Mac paths in place.
"""
import asyncio
import plistlib
import re
from urllib.parse import urlsplit
from uuid import uuid4

from pyatv import exceptions
from pyatv.protocols.airplay.auth import extract_credentials
from pyatv.protocols.airplay.utils import AirPlayFlags, parse_features
from pyatv.protocols.raop.protocols import StreamContext
from pyatv.protocols.raop.protocols.airplayv2 import AirPlayV2
from pyatv.support.http import decode_bplist_from_body, http_connect
from pyatv.support.rtsp import RtspSession

from transport_cleanup import timing_server


def normalize_features(service):
    # Normalize the same service pyatv will use for pairing and connection.
    for key in ('features', 'ft'):
        value = service.properties.get(key, '')
        match = re.fullmatch(r'0x([0-9a-fA-F]{1,8}),0x([0-9a-fA-F]{1,8})', value)
        if match:
            lower, upper = match.groups()
            service.properties[key] = f'0x{lower.zfill(8)},0x{upper}'
    return parse_features(service.properties.get('features') or service.properties.get('ft') or '0x0')


def queue_item(url):
    streaming = urlsplit(url).path.lower().endswith(('.m3u8', '.m3u'))
    item = {
        'uuid': str(uuid4()).upper(),
        'Content-Location': url,
        'mediaType': 'streaming' if streaming else 'file',
        'playbackRestrictions': 0,
        'referenceRestrictions': 3,
        'supportsIntegratedTimeline': False,
        'allowedCommonMediaClientDataKeys': 0,
        'snapTimeToPausePlayback': False,
        'clientBundleID': 'dev.pyatv.GPU',
    }
    if streaming:
        invalid_time = dict(flags=0, value=0, epoch=0, timescale=0)
        item.update(timeToPausePlayback=invalid_time, timeToPauseBuffering=invalid_time)
    else:
        item['Start-Position'] = dict(flags=1, value=0, epoch=0, timescale=10**9)
    return item


class VideoSession(AirPlayV2):
    def __init__(self, context, rtsp):
        super().__init__(context, rtsp)
        self.stream_id = None
        self.playing = asyncio.Event()
        self.ended = asyncio.Event()
        self.failed = False

    def _handle_request(self, request):
        if request.path != '/command' or not request.body:
            return
        try:
            command = plistlib.loads(plistlib.loads(request.body)['params']['data'])
            kind, name = command.get('type'), command.get('name')
        except (plistlib.InvalidFileException, KeyError, AttributeError, ValueError,
                TypeError, OverflowError):
            return
        if (kind, name) == ('playbackState', 'playing'):
            self.playing.set()
        elif (kind, name) in (
            ('playbackState', 'stopped'),
            ('notification', 'itemPlayedToEnd'),
            ('notification', 'itemFailedToPlayToEnd'),
        ):
            self.failed = self.failed or name == 'itemFailedToPlayToEnd' or command.get('reason') == 'error'
            self.ended.set()

    async def setup_video(self, timing_port, receiver_id, stage):
        stage('verify-and-event-channel')
        await self._setup_base(timing_port)
        # pyatv 0.18.0 acknowledges events but offers no callback. Observe
        # decoded requests on this session only and preserve its ACK handling.
        channel = self.event_channel.get_protocol()
        parse = channel.parse_request

        def observe(data):
            request, consumed, remaining = parse(data)
            if request is not None:
                self._handle_request(request)
            return request, consumed, remaining

        channel.parse_request = observe
        stage('remote-control-stream')
        await self.rtsp.record()
        await self.start_feedback()
        response = await self.rtsp.setup(body={'streams': [{
            'type': 130,
            'controlType': 1,
            'channelID': f'{receiver_id}-RCS-2',
            'clientUUID': str(uuid4()).upper(),
            'clientTypeUUID': 'A6B27562-B43A-4F2D-B75F-82391E250194',
        }]})
        streams = decode_bplist_from_body(response)['streams']
        self.stream_id = next(stream['streamID'] for stream in streams if stream.get('type') == 130)

    async def send(self, command):
        response = await self.rtsp.exchange(
            'POST', uri='/command',
            headers={'X-Apple-StreamID': self.stream_id},
            body={'params': {'data': plistlib.dumps(command, fmt=plistlib.FMT_BINARY)}},
        )
        if not 200 <= response.code < 300:
            raise exceptions.PlaybackError('Video command rejected')

    async def play(self, url, receiver_id, started, stage):
        try:
            async with timing_server(self.rtsp) as timing:
                await self.setup_video(timing.port, receiver_id, stage)
                stage('video-queue')
                await self.send({'type': 'insertPlayQueueItem', 'item': queue_item(url)})
                await self.send({'type': 'setProperty', 'property': 'actionAtItemEnd', 'value': 1})
                await self.send({'type': 'setRate', 'rate': 1.0})
                stage('waiting-for-playing')
                while not self.ended.is_set():
                    if (self.rtsp.connection.transport is None
                            or self.event_channel.is_closing()):
                        raise exceptions.ConnectionLostError('Video session disconnected')
                    if self.playing.is_set() and not started.is_set():
                        stage('playing')
                        started.set()
                    try:
                        await asyncio.wait_for(self.ended.wait(), timeout=0.2 if not started.is_set() else 1)
                    except asyncio.TimeoutError:
                        pass
                if self.failed or not started.is_set():
                    raise exceptions.PlaybackError('Receiver stopped or rejected the media')
        finally:
            self.teardown()


async def play_video(config, service, url, started, stage, set_session):
    context = StreamContext()
    context.credentials = extract_credentials(service)
    stage('receiver-connect')
    connection = await http_connect(str(config.address), service.port)
    try:
        session = VideoSession(context, RtspSession(connection))
        set_session(session)
        await session.play(url, service.properties.get('deviceid') or service.identifier,
                           started, stage)
    finally:
        set_session(None)
        connection.close()


def video_v2_only(service):
    flags = normalize_features(service)
    return (AirPlayFlags.SupportsAirPlayVideoV2 in flags
            and AirPlayFlags.SupportsAirPlayVideoV1 not in flags)
