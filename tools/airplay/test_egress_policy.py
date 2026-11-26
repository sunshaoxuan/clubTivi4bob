import unittest
from unittest.mock import patch

from egress_policy import server_or_local_url


class SenderResourceTests(unittest.TestCase):
    def test_windows_local_recording_paths_are_not_url_schemes(self):
        with patch('egress_policy.sys.platform', 'win32'):
            for path in (r'C:\Users\QA\fixture.mp4', 'D:/QA/fixture.mp4'):
                self.assertEqual(server_or_local_url(path), path)

    def test_windows_paths_do_not_bypass_url_checks(self):
        with patch('egress_policy.sys.platform', 'win32'):
            for url in ('file:///C:/private.mp4', 'https://user:password@example.test/live',
                        'https://cndrp.com/bobtv/private.ts'):
                with self.assertRaises(ValueError):
                    server_or_local_url(url)
