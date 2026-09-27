"""Experimental URL-video session for native macOS AirPlay receivers.

Uses BobTV's verified transient authentication and the existing AirPlay 2 URL
transport. This module is deliberately separate from production discovery until
physical video playback is validated. It never requests PIN pairing.
"""
import asyncio
import contextlib
import plistlib
import time
import math

from pyatv.auth.hap_channel import setup_channel
from pyatv.protocols.airplay.channels import EventChannel
from pyatv.protocols.raop.protocols import StreamContext
from pyatv.protocols.raop.protocols.airplayv2 import AirPlayV2, HEADERS
from pyatv.support.http import decode_bplist_from_body, http_connect
from pyatv.support.rtsp import RtspSession

from mac_auth import authenticate
from mac_reverse import open_reverse
from mac_hls import MASTER_URL, fcup_response
from mac_sap import authenticate_media


class MacVideoProtocol(AirPlayV2):
    def media_time(self):
        if getattr(self, 'clock_anchor', None) is not None:
            return self.clock_anchor + time.monotonic() - self.clock_local
        return time.time() + 2208988800

    async def play_url(self, timing_server_port, url, position=0.0):
        await self._setup_base(timing_server_port)
        if not getattr(self, 'url_only', False):
            await self.start_feedback()
            await self.rtsp.record()
        self.headers = dict(HEADERS, **{'X-Apple-Session-ID': self.uuid,
                                      'X-Apple-Device-ID': '0x02424F425456'})
        await self.rtsp.connection.send_and_receive('GET', '/server-info',
                                                   headers=self.headers, allow_error=True)
        self.reverse_tasks = set()
        def reverse_event(request):
            diagnostic = getattr(self, 'diagnostic', None)
            body = None
            if diagnostic:
                detail = {'stage': 'reverse-event'}
                with contextlib.suppress(Exception):
                    body = plistlib.loads(request.body.encode() if isinstance(request.body, str) else request.body)
                    if isinstance(body, dict):
                        detail['bodyKeys'] = list(body)[:20]
                        detail['type'] = body.get('type') if body.get('type') in (
                            'unhandledURLRequest', 'video', 'event') else 'other'
                diagnostic(detail)
            if body is None:
                with contextlib.suppress(Exception):
                    body = plistlib.loads(request.body.encode() if isinstance(request.body, str) else request.body)
            response_body = fcup_response(body, url)
            if response_body:
                if len(self.reverse_tasks) >= 4:
                    raise RuntimeError('Too many pending reverse requests')
                async def send_manifest():
                    response = await self.rtsp.connection.post('/action', headers=self.headers,
                        body=plistlib.dumps(response_body, fmt=plistlib.FMT_BINARY), allow_error=True)
                    if diagnostic:
                        diagnostic({'stage': 'fcup-response', 'status': response.code,
                                    'manifestStatus': response_body['params']['FCUP_Response_StatusCode']})
                task = asyncio.create_task(send_manifest())
                self.reverse_tasks.add(task)
                def finished(item):
                    self.reverse_tasks.discard(item)
                    if not item.cancelled() and item.exception() and diagnostic:
                        diagnostic({'stage': 'fcup-response', 'errorType': type(item.exception()).__name__})
                task.add_done_callback(finished)
        self.reverse_connection = await open_reverse(
            self.rtsp.connection.remote_ip, self.control_port, self.uuid, reverse_event)
        response = await self.rtsp.connection.post('/play', headers=self.headers,
            body=plistlib.dumps({'Content-Location': MASTER_URL,
                                'Start-Position-Seconds': position,
                                'uuid': self.uuid, 'streamType': 1,
                                'mediaType': 'file', 'rate': 1.0,
                                'clientBundleID': 'io.github.clubanderson.BobTV',
                                'clientProcName': 'BobTV'}, fmt=plistlib.FMT_BINARY),
            allow_error=True)
        self.playback_request_sent = response.code == 200
        if response.code == 200:
            await self.rtsp.exchange('POST', uri='/rate?value=1.000000')
        return response

    async def _setup_base(self, timing_server_port):
        self._verifier = await authenticate(self.rtsp.connection)
        if getattr(self, 'media_auth_helper', None):
            await authenticate_media(self.rtsp, self.media_auth_helper, getattr(self, 'diagnostic', None))
        if getattr(self, 'url_only', False):
            return
        if getattr(self, 'diagnostic', None):
            self.diagnostic({'stage': 'control-setup-start'})
        response = await self.rtsp.setup(body={
            'deviceID': '02:42:4F:42:54:56',
            'macAddress': '02:42:4F:42:54:56',
            'sessionUUID': self.uuid.upper(),
            'name': 'BobTV', 'model': 'iPhone14,3',
            'osName': 'iPhone OS', 'osVersion': '16.5',
            'sourceVersion': '690.7.1',
            'timingProtocol': 'NTP', 'timingPort': timing_server_port,
            'isMultiSelectAirPlay': True,
            'isScreenMirroringSession': getattr(self, 'frame_stream', False),
            'groupContainsGroupLeader': False, 'senderSupportsRelay': False,
        })
        self.session_established = True
        self.clock_anchor = None
        with contextlib.suppress(ValueError, TypeError, AttributeError):
            received = float(response.headers.get('X-Apple-RequestReceivedTimestamp',
                             response.headers.get('x-apple-requestreceivedtimestamp')))
            processing = float(response.headers.get('X-Apple-ProcessingTime',
                               response.headers.get('x-apple-processingtime', 0)))
            if math.isfinite(received) and math.isfinite(processing):
                self.clock_anchor = (received + processing) / 1000
                self.clock_local = time.monotonic()
        if getattr(self, 'diagnostic', None):
            self.diagnostic({'stage': 'receiver-clock', 'provided': self.clock_anchor is not None,
                             'ntpDeltaSeconds': round(self.media_time() - time.time() - 2208988800, 3)})
        info = decode_bplist_from_body(response)
        port = info.get('eventPort')
        if not isinstance(port, int) or not 1 <= port <= 65535:
            raise ValueError('Mac did not return a valid event port')
        diagnostic = getattr(self, 'diagnostic', None)

        class ObservedEvents(EventChannel):
            @staticmethod
            def parse_request(data):
                request, raw, rest = EventChannel.parse_request(data)
                if request and diagnostic:
                    detail = {'stage': 'event', 'endpoint': request.path.split('?')[0]}
                    with contextlib.suppress(Exception):
                        body = plistlib.loads(request.body)
                        if isinstance(body, dict):
                            detail['bodyKeys'] = list(body)[:20]
                            if body.get('type') in ('updateInfo', 'unhandledURLRequest', 'event'):
                                detail['type'] = body['type']
                            if body.get('type') == 'updateInfo' and isinstance(body.get('value'), dict):
                                value = body['value']
                                detail['capabilities'] = {key: value[key] for key in (
                                    'features', 'playbackCapabilities', 'supportedFormats',
                                    'hasUDPMirroringSupport', 'canRecordScreenStream') if key in value}
                    diagnostic(detail)
                return request, raw, rest

        self.event_channel, _ = await asyncio.wait_for(setup_channel(
            ObservedEvents, self._verifier, self.rtsp.connection.remote_ip, port,
            'Events-Salt', 'Events-Read-Encryption-Key',
            'Events-Write-Encryption-Key'), 8)


async def play_mac_url(address, port, url, diagnostic=None, url_only=False, media_auth_helper=None):
    """Play until stopped/cancelled, always closing timing and event sockets."""
    connection = await asyncio.wait_for(http_connect(address, port), 8)
    if diagnostic:
        exchange = connection.send_and_receive

        async def observed(method, uri, *args, **kwargs):
            # Only fixed protocol endpoint names are exposed, never bodies/URLs.
            endpoint = uri.split('?')[0] if uri.startswith('/') else 'session'
            try:
                response = await exchange(method, uri, *args, **kwargs)
            except Exception as error:
                diagnostic({'method': method, 'endpoint': endpoint,
                            'errorType': type(error).__name__})
                raise
            details = {'method': method, 'endpoint': endpoint, 'status': response.code}
            if endpoint in ('/play', '/playback-info') and response.body:
                details['bodyBytes'] = len(response.body)
                with contextlib.suppress(Exception):
                    decoded = plistlib.loads(response.body)
                    if isinstance(decoded, dict):
                        details['bodyKeys'] = list(decoded)
                        error = decoded.get('error')
                        if isinstance(error, dict) and isinstance(error.get('code'), int):
                            details['receiverErrorCode'] = error['code']
            diagnostic(details)
            return response

        connection.send_and_receive = observed
    rtsp = RtspSession(connection)
    protocol = MacVideoProtocol(StreamContext(), rtsp)
    protocol.control_port = port
    protocol.url_only = url_only
    protocol.media_auth_helper = media_auth_helper
    protocol.diagnostic = diagnostic
    # The upstream timing_server context lacks try/finally during cancellation.
    # Own the UDP transport here instead so repeated channel changes cannot leak it.
    from pyatv.protocols.raop.protocols import TimingServer
    transport = None
    try:
        transport, timer = await asyncio.get_running_loop().create_datagram_endpoint(
            TimingServer, local_addr=(connection.local_ip, 0))
        response = await asyncio.wait_for(protocol.play_url(timer.port, url), 20)
        if response.code != 200:
            raise RuntimeError(f'Mac video request failed: HTTP {response.code}')
        # Keep the same AirPlay session identity as the accepted /play request.
        started = False
        while True:
            response = await connection.send_and_receive(
                'GET', '/playback-info', headers=getattr(protocol, 'headers', HEADERS), allow_error=True)
            if response.code in (404, 500, 501):
                # A Mac can accept /play while failing this Apple TV polling
                # endpoint. Keep the session alive for caller-controlled
                # cancellation; this is NOT evidence that video started.
                await asyncio.Future()
            if response.code != 200:
                raise RuntimeError(f'Mac playback status failed: HTTP {response.code}')
            info = decode_bplist_from_body(response) if response.body else {}
            if 'error' in info:
                raise RuntimeError('Mac reported a video decoding error')
            if 'duration' in info:
                started = True
            elif started:
                return
            await asyncio.sleep(1)
    finally:
        feedback = protocol._feedback_task
        protocol.teardown()
        if url_only and getattr(protocol, 'playback_request_sent', False):
            with contextlib.suppress(Exception):
                await asyncio.wait_for(connection.post('/stop', headers=protocol.headers,
                                                        allow_error=True), 2)
        if getattr(protocol, 'session_established', False):
            with contextlib.suppress(Exception):
                await asyncio.wait_for(rtsp.exchange('TEARDOWN', allow_error=True), 2)
        reverse = getattr(protocol, 'reverse_connection', None)
        if reverse:
            reverse.close()
        reverse_tasks = list(getattr(protocol, 'reverse_tasks', ()))
        for task in reverse_tasks:
            task.cancel()
        if reverse_tasks:
            await asyncio.gather(*reverse_tasks, return_exceptions=True)
        if transport:
            transport.close()
        connection.close()
        if feedback:
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await feedback
