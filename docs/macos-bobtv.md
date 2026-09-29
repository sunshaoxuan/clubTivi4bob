# BobTV on macOS

The Flutter player, channel database and interface are shared with Windows.
Platform-specific code is kept in `macos/`, `tools/macos/`,
`lib/data/services/mac_update_service.dart` and the macOS branches of the
AirPlay helper and fingerprint service. The Windows executable, PowerShell
updater and Windows identity script remain independent.

## Build

Use a Mac with full Xcode, CocoaPods, Flutter, Python 3.12 and Go installed.
Check out the FPSAP source at revision
`370f9db2e26b21b4a710bdba5d51012c1239e736`, then run:

```sh
bash tools/macos/build.sh /path/to/clean/fpsap-source
```

The script builds `BobTV.app` and embeds the isolated AirPlay helper and its
authentication adapter. The adapter's corresponding source and license notices
are copied into the bundle. GitHub Actions builds separate Intel and Apple
Silicon DMGs. A self-contained FFmpeg executable can be included by setting
`BOBTV_FFMPEG_BIN`, `BOBTV_FFMPEG_LICENSE` and `BOBTV_FFMPEG_SOURCE` before
building. Its linked libraries and corresponding source obligations must be
covered. Otherwise the user needs FFmpeg at
`/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg` or on `PATH` for AirPlay
transcoding and the MPEG-TS audio proxy. Basic media_kit playback does not
require the FFmpeg command-line executable.

For distribution, set `BOBTV_CODESIGN_IDENTITY` to the Developer ID identity
before building, then notarize and staple the DMG. An unsigned CI artifact is
only a test package. The in-app updater rejects unsigned or differently signed
replacements.

## Updates

Release builds check the architecture-specific manifest at
`https://bobtv.briconbric.com/updates/macos-x64/latest.json` or
`https://bobtv.briconbric.com/updates/macos-arm64/latest.json` on startup and
every six hours. A missing manifest means no approved Mac update is available.
An optional `update-manifest-url.txt` in the app's Update support directory can
select a different path on the same HTTPS host for staged testing.
The schema matches `UpdateManifest`; its archive must be a ZIP with one
`BobTV.app/` root. Use separate Intel and Apple Silicon manifests and archives.
The candidate app must have the declared version and bundle ID, pass macOS
signature and Gatekeeper checks, and use the same Apple Team ID as the installed
app. The worker downloads in the background and installs after BobTV closes.
The previous app is backed up. Startup health is counted when the channel
browser becomes available; three consecutive unclean launches trigger a
rollback and skip that version.

The current CI Mac packages are unsigned test artifacts and are excluded from
the automatic update feed. Publish a Mac package only after Developer ID
signing, notarization, Gatekeeper verification and an installation test. The
`tools/macos/package_signed_update.sh` helper validates the signed bundle,
submits it for Apple notarization, staples the result and creates an
architecture-specific ZIP and matching `BobTV-update-metadata.json`. It needs
a Developer ID identity when the app is built and App Store Connect notarization
credentials when packaging. Upload both files to a GitHub release only after
testing the packaged app on the corresponding Mac architecture. The first
signed update can migrate an existing ad-hoc BobTV test installation after
checking its bundle ID and local signature. Later updates require the same
Apple Team ID as the installed app. The
updater needs write access to the parent of the installed `.app`. When
BobTV is installed in a protected system directory without that access, the
worker keeps the current app and reports a failed update. The native macOS
entry point marks candidate startup before the Flutter interface loads. Failed
version reports remain local. Ordinary diagnostic snapshots can use the
existing consent-gated log API; the updater never uploads raw logs.

## Local data

Mac AirPlay pairings and native-cast diagnostics are stored under
`~/Library/Application Support/BobTV/AirPlay/`. The client fingerprint is
stored under the application's support directory. The fingerprint combines
the Mac platform UUID with an installation salt and hashes them; the raw UUID
is not transmitted. An existing valid fingerprint is reused across upgrades.
