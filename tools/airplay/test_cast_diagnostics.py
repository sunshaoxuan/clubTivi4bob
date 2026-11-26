import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from cast_diagnostics import record, failure_details, request_id, record_network


class DiagnosticTests(unittest.TestCase):
    def test_native_error_keeps_cause_location_and_correlation_without_raw_message(self):
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as folder, \
             patch.dict(os.environ, {'LOCALAPPDATA': folder}), contextlib.redirect_stdout(output):
            token = request_id.set('ab' * 16)
            try:
                try:
                    raise FileNotFoundError(2, 'https://user:secret@private/token')
                except FileNotFoundError as error:
                    record({'stage': 'command-failed', **failure_details(error)})
            finally:
                request_id.reset(token)
        event = json.loads(output.getvalue())
        self.assertEqual(event['errorCode'], 'missing_dependency')
        self.assertEqual(event['osErrorCode'], 2)
        self.assertEqual(event['requestId'], 'ab' * 16)
        self.assertIn('test_native_error_keeps_cause_location', event['nativeStackFrames'])
        self.assertNotIn('secret', output.getvalue())

    def test_local_route_probe_records_actual_socket_source_without_sending_media(self):
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as folder, \
             patch.dict(os.environ, {'LOCALAPPDATA': folder}), contextlib.redirect_stdout(output):
            record_network('127.0.0.1', 7000)
        event = json.loads(output.getvalue())
        self.assertEqual(event['localAddress'], '127.0.0.1')
        self.assertEqual(event['receiverAddress'], '127.0.0.1')
        self.assertEqual(event['localAddressSource'], 'socket_route')
        if __import__('sys').platform == 'darwin':
            self.assertEqual(event['sameSubnet'], True)
            self.assertEqual(event['prefixLength'], 8)

    def test_source_urls_and_arbitrary_error_text_are_never_persisted(self):
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {'LOCALAPPDATA': folder}), contextlib.redirect_stdout(output):
            record({'stage': 'sender-failed', 'url': 'https://secret/token',
                    'reason': 'https://secret/token', 'errorType': 'TimeoutError', 'count': 50})
            raw = (Path(folder) / 'BobTV/AirPlay/native-cast.log').read_text()
            self.assertNotIn('secret', raw)
            self.assertNotIn('secret', output.getvalue())
            self.assertEqual(json.loads(output.getvalue())['event'], 'diagnostic')
            self.assertEqual(json.loads(raw)['errorType'], 'TimeoutError')

    def test_log_rotates_at_bounded_size(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {'LOCALAPPDATA': folder}):
            record({'stage': 'start'})
            path = Path(folder) / 'BobTV/AirPlay/native-cast.log'
            path.write_text('x' * (256 * 1024 + 1))
            record({'stage': 'next'})
            self.assertLess(path.stat().st_size, 1024)
            self.assertTrue(path.with_name('native-cast.previous.log').exists())
