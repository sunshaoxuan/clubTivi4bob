from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]


def test_android_output_is_owned_by_the_native_surface_controller():
    for filename in ('player_service.dart', 'multi_view_screen.dart'):
        source = (ROOT / 'lib/features/player' / filename).read_text()
        assert not re.search(r"setProperty\('vo',\s*'gpu'\)", source)
        assert "'mediacodec-copy'" not in source
    native = (ROOT / 'third_party/media_kit_video/lib/src/video_controller/android_video_controller/real.dart').read_text()
    assert "widValue == '0' ? 'null'" in native
    assert "'auto-safe'" in native


def test_private_update_files_are_not_exposed_by_fileprovider():
    source = (ROOT / 'android/app/src/main/res/xml/file_paths.xml').read_text()
    assert 'path="BobTVUpdates/"' in source
    assert 'path="."' not in source
    manifest = (ROOT / 'android/app/src/main/AndroidManifest.xml').read_text()
    assert 'android:allowBackup="false"' in manifest
    assert 'android:usesCleartextTraffic="false"' in manifest
