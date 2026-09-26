"""Bounded AirPlay reverse HTTP event channel for native receiver experiments."""
import asyncio

from pyatv.support.http import (HttpConnection, HttpResponse, format_response,
                                parse_request, parse_response)
from mac_auth import authenticate


class ReverseConnection(HttpConnection):
    def __init__(self, on_event):
        super().__init__()
        self.on_event = on_event
        self.upgraded = False
        self.failure = None

    def data_received(self, data):
        try:
            self._buffer += self.receive_processor(data)
            if len(self._buffer) > 1024 * 1024:
                raise ValueError('Reverse event exceeds buffer limit')
            while self._buffer:
                if not self.upgraded:
                    response, remainder = parse_response(self._buffer)
                    if response is None:
                        return
                    self._buffer = remainder
                    self.upgraded = response.code == 101
                    if self._requests:
                        request = self._requests.pop()
                        request.response = response
                        request.event.set()
                else:
                    request, remainder = parse_request(self._buffer)
                    if request is None:
                        return
                    self._buffer = remainder
                    accepted = request.method == 'POST' and request.path == '/event'
                    response = HttpResponse('HTTP', '1.1', 200 if accepted else 404,
                                            'OK' if accepted else 'Not Found',
                                            {'Content-Length': '0'}, b'')
                    self.transport.write(self.send_processor(format_response(response)))
                    if accepted:
                        self.on_event(request)
        except Exception:
            # No response body or credential material is exposed by diagnostics.
            self.failure = 'reverse-event-decode-failed'
            self.close()


async def open_reverse(address, port, session_id, on_event):
    _, connection = await asyncio.wait_for(asyncio.get_running_loop().create_connection(
        lambda: ReverseConnection(on_event), address, port), 8)
    try:
        await authenticate(connection)
        response = await connection.post('/reverse', headers={
            'User-Agent': 'AirPlay/550.10', 'Connection': 'Upgrade',
            'Upgrade': 'PTTH/1.0', 'X-Apple-Purpose': 'event',
            'X-Apple-Device-ID': '0x02424F425456',
            'X-Apple-Session-ID': session_id}, allow_error=True)
        if response.code != 101:
            raise RuntimeError(f'Reverse channel rejected: HTTP {response.code}')
        return connection
    except BaseException:
        connection.close()
        raise
