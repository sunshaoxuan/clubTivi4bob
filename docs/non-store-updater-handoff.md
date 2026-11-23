# Self-distributed updater components (unreleased)

Currently supported website distribution covers Windows Setup, Windows portable
ZIP, macOS and Android APK. Store-managed packages retain their platform update
mechanism. No new app release or online feed change is included in this work.

## Windows Setup and portable ZIP

The release finalizer produces one small updater ZIP for each Windows platform,
signs it with the existing publisher key and adds an `updater` entry to the main
update metadata. This ZIP contains both installation workers, the signature
verifier, progress window and pinned public key. Its signed `updater.json` binds
protocol 1, the exact native target version and both Windows installation modes.
The public component filename has the semantic version only.

The mirror verifies the component's size, checksum, signature, exact file list and
compatibility metadata before publishing it. Approval registries and historical
feeds retain the component alongside its app package. Release alignment and
checksums include both Windows component assets.

Before launching an installation worker, the player invokes its bundled minimal
preparer. The preparer authenticates the component with the bundled pinned key,
checks bounded extraction, exact filenames, script syntax and compatibility, then
atomically moves it into a unique directory. Failed verification never starts new
code. Cached archive bytes are checked again. Both new workers continue to use
the established installation lock, authorization, backup and recovery flow. The
progress window reads the existing per-run state directory explicitly.

Old feeds without an updater entry keep the existing bundled-worker path. Clients
need a main-app release containing the preparer to use independently delivered
components. This does not modify already installed 1.4.4 clients.

## macOS

The signed target app supplies the replacement worker and progress window after
archive and app verification. The bootstrap hands over the existing installation
lock and reuses downloaded bytes. Installation waits for the player to exit.
See `macos-distribution.md` for compatibility and acceptance checks.

## Android APK

The update service is packaged inside the APK and is replaced atomically with the
app. Downloaded APKs go through BobTV's existing Android package-installer bridge,
including platform permission and installation confirmation. Desktop workers are
not applied to APK installation. No separately downloaded executable update code
or change to the existing Android update feed is introduced.

## Verification

- `flutter test test/update_manifest_test.dart test/desktop_update_feedback_test.dart test/desktop_update_check_tile_test.dart`
- `pytest website/tests/test_updater_bundle.py website/tests/test_mirror.py website/tests/test_release_alignment.py website/tests/test_finalize_update_metadata.py website/tests/test_update_delivery.py`
- `tools/windows/test_toolchain_prepare.ps1` takes isolated fixture keys, metadata
  and a signed component. Windows PowerShell 5.1 acceptance verifies actual CNG
  signatures, both worker modes, rejection of signature/version/path mismatches
  and absence of installation side effects. No player is launched.

Production installer/UAC acceptance and Windows ARM64 execution still belong to
the next formal release test matrix. The changes are source-only until release.
