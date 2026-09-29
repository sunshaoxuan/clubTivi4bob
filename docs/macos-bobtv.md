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

Without an Apple Developer ID, the build script ad-hoc signs the completed
bundle so macOS can verify its local integrity. A Developer ID and Apple
notarization remain optional distribution improvements. The BobTV update
signature below independently authenticates self-hosted update ZIPs.

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
code-signature integrity checks, and have a BobTV publisher signature over the
exact ZIP bytes. The site's mirror verifies the same signature before it
publishes the manifest. The worker downloads in the background and installs
after BobTV closes.
The previous app is backed up. Startup health is counted when the channel
browser becomes available; three consecutive unclean launches trigger a
rollback and skip that version.

CI Mac test packages are excluded from the automatic update feed until a
publisher-signed release ZIP is created. Set `BOBTV_UPDATE_SIGNING_KEY` to the
private P-256 key stored outside the repository, then run
`tools/macos/package_signed_update.sh BobTV.app arm64 output-directory` (or
`x64`). The helper checks the bundle, creates an architecture-specific ZIP,
signs its exact bytes and writes `BobTV-update-metadata.json` with the
base64 signature. It checks the signature against the public key embedded in
BobTV before producing metadata. The private key must never be committed or
copied into the package. Upload both files to a GitHub release only after
testing that architecture. The website's mirror downloads and validates the
release, then serves the manifest and ZIP from its own HTTPS origin. Optional
`NOTARY_KEY`, `NOTARY_KEY_ID`, and `NOTARY_ISSUER` enable Apple notarization.
Without notarization, a first installation on a different Mac may require a
one-time approval in macOS Privacy & Security. The
updater needs write access to the parent of the installed `.app`. When
BobTV is installed in a protected system directory without that access, the
worker keeps the current app and reports a failed update. Install into a
user-writable directory such as `~/Applications` for silent replacement.
The native macOS
entry point marks candidate startup before the Flutter interface loads. Failed
version reports remain local. Ordinary diagnostic snapshots can use the
existing consent-gated log API; the updater never uploads raw logs.

## Local data

Mac AirPlay pairings and native-cast diagnostics are stored under
`~/Library/Application Support/BobTV/AirPlay/`. The client fingerprint is
stored under the application's support directory. The fingerprint combines
the Mac platform UUID with an installation salt and hashes them; the raw UUID
is not transmitted. An existing valid fingerprint is reused across upgrades.
