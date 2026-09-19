import asyncio
import plistlib
import unittest
from unittest.mock import Mock

from mac_reverse import ReverseConnection


class ReverseTests(unittest.IsolatedAsyncioTestCase):
    def event(self, path='/event'):
        body = plistlib.dumps({'type': 'unhandledURLRequest'})
        return (f'POST {path} HTTP/1.1\r\nContent-Length: {len(body)}\r\n\r\n'.encode() + body)

    def connection(self):
        callback = Mock()
        connection = ReverseConnection(callback)
        connection.transport = Mock()
        return connection, callback

    async def test_upgrade_and_event_in_same_packet(self):
        connection, callback = self.connection()
        pending = connection.PendingRequest(event=asyncio.Event())
        connection._requests.append(pending)
        connection.data_received(b'HTTP/1.1 101 Switching Protocols\r\n\r\n' + self.event())
        self.assertTrue(pending.event.is_set())
        self.assertEqual(pending.response.code, 101)
        callback.assert_called_once()
        self.assertIn(b'200 OK', connection.transport.write.call_args.args[0])

    async def test_fragmented_event(self):
        connection, callback = self.connection()
        connection.upgraded = True
        message = self.event()
        for fragment in (message[:3], message[3:40], message[40:]):
            connection.data_received(fragment)
        callback.assert_called_once()
        self.assertFalse(connection._buffer)

    async def test_unsupported_endpoint_is_not_dispatched(self):
        connection, callback = self.connection()
        connection.upgraded = True
        connection.data_received(self.event('/other'))
        callback.assert_not_called()
        self.assertIn(b'404', connection.transport.write.call_args.args[0])

    async def test_buffer_limit_closes_connection(self):
        connection, callback = self.connection()
        transport = connection.transport
        connection.data_received(b'x' * (1024 * 1024 + 1))
        transport.close.assert_called_once()
        callback.assert_not_called()
        self.assertEqual(connection.failure, 'reverse-event-decode-failed')
