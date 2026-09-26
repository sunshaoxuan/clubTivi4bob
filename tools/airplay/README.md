# BobTV AirPlay helper

## Native Mac video casting

`mac_auth.py` implements a separate transient SRP handshake without
requesting an on-screen PIN. It validates TLV framing, receiver state and the
server's SRP proof before deriving control/event encryption keys. Access denials
and backoff responses are terminal; it never guesses PINs or retries an access
denial. `test_mac_auth.py` exercises both sides of a real SRP exchange, rejects
invalid proofs and verifies that denied requests cannot enable encryption.

On the receiving Mac, enable AirPlay Receiver, allow Everyone and disable
Require Password. BobTV then uses transient authentication, with no four-digit
PIN dialog. Account-only and password-protected receivers are rejected clearly.
The native path becomes available when the packaged `fpsap-auth.exe` and FFmpeg
are present. Other AirPlay video receivers retain the existing URL/HLS path.

The selected HTTP(S) video is decoded by one FFmpeg process and transmitted as
encrypted H.264 video and stereo ALAC audio. Only video content is sent; the
desktop and other windows are never captured. The initial compatibility profile
is **1280×720 at 25 fps**, with two encoding threads and bounded pipe/NAL buffers.
Video uses the Mac's monotonic media clock; type-96 audio uses the NTP epoch.
RTP sequence wrap does not reset the 64-bit audio encryption nonce. Stop and
channel changes cancel the previous session and close its decoder and sockets.
Native-Mac remote pause/resume/volume controls are not yet enabled; adjust volume
on the Mac. A source must contain both video and audio for this initial profile.

**Physical validation on 2026-09-20:** the owner confirmed continuously advancing
`LIVE FRAME` video and audible test audio on a native MacBookPro16,2 receiver.
The live pipeline sent more than 750 frames, completed TEARDOWN with HTTP 200,
and exited its FFmpeg process. A static first frame was traced to the wrong
video clock domain. Intermittent SETUP timeouts were resolved in the test by
allowing the receiver's UDP timing requests. Install the executable-scoped
firewall rules below; successful discovery alone does not prove timing access.
Other Mac models and long-duration A/V drift still need physical validation.

`mac_video.py` contains the shared session and redacted per-stage
diagnostics. Its cancellation cleanup closes timing/event/control transports and
attempts bounded TEARDOWN. `probe_mac_video.py` is a developer-only Windows test:
it generates a short synthetic video, creates a temporary receiver-IP/port-scoped
firewall rule, and removes the rule and media on completion. It is not a bundled
user feature. Native-Mac unit tests cover SRP proofs, framing validation,
access denial, session identity, event-port validation, cancellation cleanup,
HLS request scoping, video packet authentication and audio nonce uniqueness.
`mac_reverse.py` and `mac_hls.py` preserve the unsuccessful direct-URL/FCUP
experiments for regression tests; the production Mac sender does not use them.
URL playback returned 200 but produced no media requests on the tested Mac.
`transport_cleanup.py` fixes cancellation cleanup in the pinned pyatv timing
context, preventing leaked UDP sockets during ordinary URL channel switching.

## Apple TV and compatible URL receivers

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
build/airplay-venv/Scripts/python.exe -m unittest discover -s tools/airplay -p 'test_*.py'
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

### Building the native authentication adapter

Use the source repository
`https://github.com/objevovat/fairplay-sap-core-airplay2-sender-authentication-handshake`
at commit `370f9db2e26b21b4a710bdba5d51012c1239e736`. With Go installed, run
`tools/airplay/build-fpsap.ps1 -SourceDirectory <clean-checkout> -OutputDirectory build/fpsap-dist`
before `build.ps1`. The build checks the exact clean revision and disables module
downloads. It packages the adapter, upstream source archive, adapter source,
build script, LGPL/GPL/Blue Oak license texts and upstream attribution notices.
The adapter performs media authentication only; it does not decrypt DRM content.

To rebuild from the bundled source archive, extract it, change to the extracted
directory containing `go.mod`, and run `go build -trimpath -o fpsap-auth.exe <absolute-path-to-fpsap_auth.go>`
with `GOOS=windows`, `GOARCH=amd64`, `CGO_ENABLED=0`, and `GOPROXY=off`.
Replace `AirPlay/fpsap-auth.exe` with the rebuilt compatible adapter. BobTV does
not impose a binary hash check on user-rebuilt adapters. AirSpan's MIT attribution
is retained in `AIRSPAN-LICENSE.txt` for the video/audio wire-layout reference.
