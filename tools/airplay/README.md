# BobTV AirPlay helper

Windows BobTV uses a bundled, isolated pyatv process to discover AirPlay video
receivers, pair using the television's four digit PIN and send HTTP(S) video URLs.
The fullscreen cast picker includes a mouse operated numeric keypad and re-pair
button. Pairings persist under `%LOCALAPPDATA%\BobTV\AirPlay\pairings.json`.
That file is private user data and must never be included in Git or packages.

BobTV forwards the currently selected video through a bounded HLS relay by
default. FFmpeg copies the video codec and converts audio to stereo AAC. Six
segments plus two expired segments are retained, and the temporary directory is
deleted on stop or channel change. A 192 MB watchdog stops abnormal growth.
Only the selected receiver IP can fetch the
unguessable playback URL. The relay binds the LAN interface reaching the receiver.
Disable the relay switch in the cast picker to send the original HTTP(S) URL
directly instead. FFmpeg must be available in BobTV's Tools directory or PATH.

This is video casting. Screen mirroring and AirPlay audio-only speakers are
not implemented. Receivers advertising only mirroring or audio are excluded.
The receiver must decode the original video codec. Per-source HTTP headers,
DRM, and receivers requiring an AirPlay password are not
supported. Support varies with receiver firmware. A sent request is not proof
that the television decoded video; BobTV reports asynchronous failures separately.
Pause and volume support depend on receiver capabilities, with visible fallback
messages directing users to their television remote.

The current selected source, manual channel changes and successful automatic
source changes are sent to the active receiver. Requests are serialized, queued
superseded channel changes are discarded, and requests have timeouts. The helper
uses private stdin/stdout pipes and does not expose an HTTP control service.
The relay exposes only the short-lived HLS media to the selected receiver.

## Build and test

On Windows, with Python 3.12 and Flutter available:

```powershell
powershell -ExecutionPolicy Bypass -File tools/airplay/build.ps1
build/airplay-venv/Scripts/python.exe -m unittest discover -s tools/airplay -p test_bridge.py
flutter build windows --release
```

CMake copies `build/airplay-dist/bobtv-airplay` into the release `AirPlay` folder.
Ship the complete folder next to the application executable. Users do not need
to install Python. The helper includes pyatv (MIT) and its dependencies; retain
their bundled license metadata. The helper only starts when the cast picker is
used and exits when BobTV closes.

For LAN discovery and relaying, run `tools/airplay/install-firewall.ps1` with
the installed application directory as `-ApplicationDirectory`. Its inbound
rules apply only to the helper executable and local subnet, including when the
Ethernet connection is classified as public by Windows.

The automated integration test sends actual AirPlay binary-plist HTTP requests
through pyatv to a simulated receiver, checks replacement playback and cleanup.
Physical receiver pairing and decoding still require device validation.
