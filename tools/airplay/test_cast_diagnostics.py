import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from cast_diagnostics import record


class DiagnosticTests(unittest.TestCase):
    def test_source_urls_and_arbitrary_error_text_are_never_persisted(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {'LOCALAPPDATA': folder}):
            record({'stage': 'sender-failed', 'url': 'https://secret/token',
                    'reason': 'https://secret/token', 'errorType': 'TimeoutError', 'count': 50})
            raw = (Path(folder) / 'BobTV/AirPlay/native-cast.log').read_text()
            self.assertNotIn('secret', raw)
            self.assertEqual(json.loads(raw)['errorType'], 'TimeoutError')

    def test_log_rotates_at_bounded_size(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {'LOCALAPPDATA': folder}):
            record({'stage': 'start'})
            path = Path(folder) / 'BobTV/AirPlay/native-cast.log'
            path.write_text('x' * (256 * 1024 + 1))
            record({'stage': 'next'})
            self.assertLess(path.stat().st_size, 1024)
            self.assertTrue(path.with_name('native-cast.previous.log').exists())
