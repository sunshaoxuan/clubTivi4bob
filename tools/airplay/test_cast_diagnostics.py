import contextlib
import io
import json
import os
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from cast_diagnostics import record, failure_details, request_id, record_network, FFmpegErrorReporter


class DiagnosticTests(unittest.TestCase):
    def test_windows_probe_timeout_retains_duration_and_cause(self):
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as folder, \
             patch.dict(os.environ, {'LOCALAPPDATA': folder}), \
             patch('cast_diagnostics.sys.platform', 'win32'), \
             patch('cast_diagnostics.subprocess.check_output', side_effect=subprocess.TimeoutExpired('powershell.exe', 15)), \
             contextlib.redirect_stdout(output):
            record_network('127.0.0.1', 7000)
        event = json.loads(output.getvalue())
        self.assertEqual(event['networkProbe'], 'partial')
        self.assertEqual(event['errorCode'], 'timeout')
        self.assertEqual(event['errorType'], 'TimeoutExpired')
        self.assertGreaterEqual(event['networkProbeDurationMs'], 0)
        self.assertEqual(event['localAddress'], '127.0.0.1')

    def test_encoder_dependency_and_split_stderr_errors_are_classified_without_secrets(self):
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as folder, \
             patch.dict(os.environ, {'LOCALAPPDATA': folder}), contextlib.redirect_stdout(output):
            reporter = FFmpegErrorReporter('decoder-error')
            reporter.feed(b"https://user:private-token@example.test/live Unknown enc")
            reporter.feed(b"oder 'libx264'\n")
            reporter.feed(b"Unknown encoder 'libx264'\nCannot allocate memory\n")
            raw = (Path(folder) / 'BobTV/AirPlay/native-cast.log').read_text()
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(events), 2)
        self.assertEqual(events[0]['reason'], 'encoder_unavailable')
        self.assertEqual(events[0]['errorCode'], 'missing_dependency')
        self.assertEqual(events[1]['errorCode'], 'out_of_memory')
        for text in (raw, output.getvalue()):
            self.assertNotIn('private-token', text)
            self.assertNotIn('example.test', text)

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
