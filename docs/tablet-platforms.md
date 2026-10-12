# Android tablets and Windows ARM64

Release version: `1.1.0+93`. Windows x64, both Mac CPU variants and Android
APKs are distributed together. Native Windows ARM64 is still under development.

## Android

The tablet entry point uses the same simple channel browser, cards, programme
guide, modern settings, favorites, channel merge and category-edit workflows
as the desktop app. Landscape tablets use the split view; narrower or portrait
windows put the video above the channel list. Long press opens the same channel
menu as desktop right click. Single tap starts a silent preview; tapping the
ready preview switches it to the main player. Double tap requests direct play.

Native `UiModeManager` identifies actual televisions. Display density or
landscape orientation never turns a touch tablet into a television.

All video widgets preserve the source aspect ratio with `BoxFit.contain`.
Letterboxing is intentional. Native Android output and decoder choice belong
to `AndroidVideoController`, which waits for a valid Surface before enabling
video output and provides safe decoder fallback. Main/preview media buffers
are 48/24 MiB on Android; the existing desktop budgets remain unchanged.

The signed APKs target ARM64, ARM32 and x64. The minimum system is Android 7
(API 24), matching the installed Flutter SDK's minimum. Android 8 and later
can use native picture in picture when the device exposes that feature.
Xiaomi HyperOS devices that support Android APK applications are the intended
tablet target. Device-specific playback, rotation, PiP and power-management
behavior still need physical Xiaomi Pad testing.

Application identity is `com.briconbric.bobtv`, separate from upstream
clubTivi. The app fingerprint uses a hash of Android's app-scoped identifier,
independent of IP, MAC address and host name. Factory reset, Android user
changes or signing-identity changes can affect the OS-provided identifier.
Android backup is disabled to avoid cloning installation identities.

Public catalog initialization, revisions, health events, retirements, manual
classification and merges use the existing shared website API. The client
checks the shared catalog periodically and queues edits durably. GitHub
discovery and AI execution stay on the server. Playback, EPG and logo resources
use the BobTV HTTPS gateway; no direct GitHub fallback is enabled.

### Android updates

Approved feeds are separate for `android-arm64`, `android-arm` and
`android-x64`. The release client checks at startup, every six hours and on a
throttled return to the foreground. A new APK downloads into the app-private
cache with visible progress and safe resume. Length, SHA-256, package identity,
newer Android version code and installed publisher certificate are checked.

The user must confirm the Android system installer. Installation permission
may need to be enabled for BobTV first. This version does not implement a
detached Android background downloader, unattended installation or automatic
APK rollback. Closing the app during download preserves the partial file for
the next retry. An absent approved feed is reported as unavailable, never as
a successful update.

Android packages and architecture-specific feeds are included in the release.
Keep the private release signing store and password outside the repository;
future APK updates must reuse the same publisher identity. Build with
`tools/android/build_apk.sh`, validate all APKs with
`tools/android/verify_apk.py`, then finalize update metadata using
`tools/finalize_desktop_update_metadata.py --platforms android-arm64 android-arm android-x64`.

## Windows Surface ARM

The shared Flutter presentation is unchanged. Native ARM64 libmpv and ANGLE
dependencies are isolated in `third_party/media_kit_libs_windows_video`.
The original Windows x64 dependency pins remain intact. Both dependency
archives are pinned to SHA-256 and all four loaded DLLs were inspected as
ARM64 PE binaries.

The installer, mirror and update feed support `windows-arm64`. The running
EXE's PE architecture selects the feed. An x64 app under Windows emulation
continues using the x64 feed. Installer and update workers reject root DLLs
from the other architecture. Software-rendering frame size calculations now
use a uniform scale for landscape, portrait, 4:3, ultrawide and 4K video.

`tools/windows/build_arm64.ps1` requires a Windows 11 ARM64 host, an ARM64
Dart runtime in its Flutter SDK, ARM64 Visual Studio release CRT files and
the independently built support components. Existing x64 AirPlay helper
processes can run under Windows 11 emulation; their libraries remain inside
the helper directory and are never loaded into the ARM64 app process. This
helper compatibility still needs actual Surface testing. Third-party binary
licenses and source notices must accompany the first native ARM64 release.

No Windows ARM64 host is available for this task. The native application,
Setup installer, automatic update/rollback and GPU behavior remain uncompiled
and unverified on actual ARM hardware. No x64 package is labeled as ARM64.

## Mainland China validation

The public HTTPS gateway was tested from the current development network
with GOOD TV and CCTV-1 playlists and media segments. This verifies server
routing only. Website throughput, startup time, continuous audio/video and
regional route selection must still be measured on a Mainland China network.
Server-side routing cannot guarantee acceptable throughput on every network.

The installed macOS and Windows apps were not restarted or replaced, and no
GitHub Actions workflow was enabled.
