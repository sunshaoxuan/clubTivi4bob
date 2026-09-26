import unittest
from mac_hls import MASTER_URL, fcup_response, master_playlist


class HlsTests(unittest.TestCase):
    def test_master_points_only_to_selected_media(self):
        response = fcup_response({'type':'unhandledURLRequest', 'request':{
            'FCUP_Response_URL':MASTER_URL, 'FCUP_Response_RequestID':17}},
            'http://192.0.2.1/selected/live.m3u8')
        self.assertEqual(response['params']['FCUP_Response_RequestID'], 17)
        self.assertEqual(response['params']['FCUP_Response_StatusCode'], 200)
        self.assertIn(b'http://192.0.2.1/selected/live.m3u8', response['params']['FCUP_Response_Data'])

    def test_receiver_cannot_request_arbitrary_urls_or_files(self):
        for url in ('file:///private/secret', 'http://127.0.0.1/secret',
                    'http://169.254.169.254/latest', 'mlhls://localhost/../secret'):
            response = fcup_response({'type':'unhandledURLRequest', 'request':{
                'FCUP_Response_URL':url}}, 'http://192.0.2.1/live.m3u8')
            self.assertEqual(response['params']['FCUP_Response_StatusCode'], 404)
            self.assertEqual(response['params']['FCUP_Response_Data'], b'')

    def test_playlist_injection_rejected(self):
        for url in ('file:///secret', 'http://example.com/x\n#EXT-X-KEY:secret'):
            with self.assertRaises(ValueError):
                master_playlist(url)

    def test_non_media_events_ignored(self):
        self.assertIsNone(fcup_response({'type':'video'}, 'http://example.com/live'))
