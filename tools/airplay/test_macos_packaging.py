import sys
import unittest
from pathlib import Path
from unittest.mock import patch

import mac_sender
from video_relay import VideoRelay


class MacPackagingTests(unittest.TestCase):
    def test_authentication_adapter_uses_native_mac_name(self):
        executable = ('/Applications/BobTV.app/Contents/Resources/AirPlay/'
                      'bobtv-airplay/bobtv-airplay')
        with patch.object(sys, 'platform', 'darwin'), patch.object(sys, 'executable', executable):
            self.assertEqual(mac_sender.authentication_helper(),
                             Path(executable).parent / 'fpsap-auth')

    def test_ffmpeg_can_be_loaded_from_app_resources(self):
        executable = ('/Applications/BobTV.app/Contents/Resources/AirPlay/'
                      'bobtv-airplay/bobtv-airplay')
        expected = Path('/Applications/BobTV.app/Contents/Resources/Tools/ffmpeg')
        with patch.object(sys, 'executable', executable), \
             patch.object(Path, 'is_file', lambda path: path == expected), \
             patch('video_relay.shutil.which', return_value=None):
            self.assertEqual(VideoRelay.ffmpeg_path(), str(expected))


if __name__ == '__main__':
    unittest.main()
