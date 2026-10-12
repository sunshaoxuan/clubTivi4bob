# Windows automatic updates

Release builds check `https://bobtv.briconbric.com/updates/windows-x64/latest.json`
on startup and every six hours. Foreground checks are additionally throttled
to once per fifteen minutes. A missing manifest is reported explicitly and means that no approved
automatic update has been published. The independent worker downloads a newer
package while BobTV runs and installs it after the app closes. Debug builds do
not poll automatically. The installed application does not need GitHub access.

Native ARM64 executables use
`https://bobtv.briconbric.com/updates/windows-arm64/latest.json`; the running
EXE determines the architecture even on an emulated host. Update staging
rejects packages whose app or root DLL architecture differs from the installed
app. ARM64 packages are cross-compiled on x64 Windows; ARM64 hardware testing
remains pending.

Checking immediately shows a spinner. Settings retains the actual result,
including up-to-date, network failure, and a skipped unhealthy version. Active
download or installation progress is not overwritten by another check.
Setup-managed installations download the publisher-authenticated Setup in the
application, with percentage and transferred bytes. No browser download,
Keep/Save confirmation, or per-update download-page navigation is needed.
The default destination remains `C:\Program Files\BoB\BoBTV`. Installing there
requires Windows administrator consent; BobTV never disables UAC or makes
Program Files writable to ordinary users. The updater itself stays unelevated.

## Platform mirror contract

The HTTPS JSON manifest has these fields:

    {
      "schema": 1,
      "version": "0.9.2+54",
      "archive": "https://bobtv.briconbric.com/updates/files/BobTV-0.9.2+54-windows-x64.zip",
      "sha256": "64 lowercase hexadecimal characters",
      "bytes": 64963783,
      "publishedAt": "2026-09-27T00:00:00Z",
      "installer": {
        "archive": "https://bobtv.briconbric.com/updates/files/BobTV-0.9.2+54-windows-x64-Setup.exe",
        "sha256": "64 lowercase hexadecimal characters",
        "bytes": 59000000,
        "signature": "base64 P-256 ECDSA DER signature"
      }
    }

The optional `installer` field is required for managed Setup updates and is
bound to the exact version and CPU architecture. BobTV checks hash, byte count,
the pinned publisher signature and Setup file version before requesting consent.
The same verified metadata is retained at
`/updates/{platform}/versions/{version}.json` for safe rollback. The worker can
download from the faster approved `cndrp.com/bobtv` resource relay, while all
metadata identities continue to use the primary HTTPS origin.

The portable ZIP must use the same HTTPS host, contain a BobTV root directory, include
BobTV.exe and data/app.so, and have an executable file version equal to the
manifest version. Its SHA-256 and byte count must match the manifest. The app
rejects redirects and archive URLs outside /updates/.

The release workflow packages a `BobTV/` rooted ZIP and produces
`BobTV-update-metadata.json` containing the exact archive hash and byte count.
The site mirror verifies both against GitHub release assets before publishing
the platform manifest. Setup hashes and publisher signatures are also verified
before the installer becomes an approved update download. Pre-existing releases without update metadata remain
available as manual downloads and do not trigger automatic installation.

Advance lib/core/app_version.dart and pubspec.yaml together for every release.
Build the Windows ZIP from that version, run the ZIP integrity check and a
Windows launch test, then publish the mirror manifest.

Finalize Windows metadata on the publisher Mac with
`tools/finalize_desktop_update_metadata.py --signing-key <local-private-key>`.
The private key must never be uploaded to GitHub, the website, or a Windows build
host. When publishing the first managed-updater release, also sign the unchanged
Setup artifacts for supported previous versions and add their historical feeds.
A missing verified rollback package pauses the upgrade explicitly.

## Installation and recovery

The independent worker downloads while the player is open. It continues after
the player closes. For managed installations it downloads the previous signed
Setup as well, then backs up the complete previous application directory
under the user's LocalAppData/HotelTV/Update/Backups directory and installs the
new files. Runtime preferences and playlists remain in the user data directory.

The update badge immediately animates while preparing the download, then shows
percentage and transferred bytes. Readiness is displayed only after package
verification and, for managed installs, the old-version backup. Clicking Install
requests native UAC consent while playback is still running. Cancelling keeps
the current application and the verified download, and permits another attempt.
Each consent request has its own ID, so stale cancellation/ready polls cannot
enable duplicate actions or close the player for an earlier request. Only after
consent does BobTV close normally; Setup waits for that exact process to exit.

On exit, an independent native window shows download, verification, consent,
backup, installation and completion. A completed update keeps that window visible
for 20 seconds and offers an Open BobTV button. Failure leaves the window open
with a readable error. Its launch button remains disabled until installed files
and their version pass verification. Cancelled consent offers the unchanged
old version; a verified restoration offers the restored old version. Closing this status window does not
cancel the update worker. Reopening BobTV observes a live task without duplicating it.

The native launcher supplies valid standard handles to the hidden PowerShell
worker and captures launch errors in `launcher.log`. Per-run status files bind
feedback to the version, run ID and process ID; missing acknowledgement and an
exited worker are reported rather than leaving a permanent new-version badge.
Installations affected by an older broken worker launcher need one manual
installation of 0.9.1+73 or later before subsequent automatic updates can work.
Older managed clients that only offer a browser download also require a one-time
installation of the managed-updater build. Publishing new metadata cannot alter
the update code already embedded in an old executable.

The Windows bootstrap records startup attempts before Flutter starts. After
the channel browser loads and remains up for 30 seconds, the startup marker is
cleared. A normal close also clears it. After three consecutive unclean
startups, the independent monitor triggers rollback immediately and remembers the failed version
in skipped_versions.txt, preventing its automatic reinstallation.
Protected installations restore through the cached, publisher-authenticated
previous Setup and request Windows consent again. Ordinary users cannot silently
replace protected Program Files contents. An interrupted or failed installation
also attempts this verified restoration. Backups and logs are retained if consent
is refused or restoration fails. No arbitrary backup script is elevated.

The rollback worker keeps a small failure record locally. It no longer sends
records to the retired `/api/update-failures` endpoint. Separately, users may
opt in to upload a restricted diagnostics summary through `POST /api/v1/logs`.
Raw logs and memory dumps are never sent by that path.

Portable updates still apply only to writable installations. Managed Program
Files installations use the separate authorized Setup flow.

## Browser trust and Authenticode

BobTV publisher signatures authenticate the update bytes inside the application.
They do not provide Windows Authenticode publisher identity or Edge SmartScreen
reputation. Without a trusted Windows code-signing certificate, a first browser
download can still warn; self-signing and disabling security protections are not
solutions. A valid certificate may improve publisher reputation, but a new file
can still receive a warning. No paid signing service is required for the in-app
download and publisher-validation mechanism.

`build_installer.ps1` supports an optional existing certificate thumbprint and
SignTool. Do not enable this unless the publisher has provisioned a trusted
certificate. See Microsoft's
[SmartScreen guidance](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation).

## Isolated validation

`test_installer_update_signature.ps1` verifies a real release signature and
rejects tampering. `test_managed_update.ps1` tests the complete consent/status and
rollback-delegation flow with process boundaries replaced by fixture doubles;
it does not automate the actual UAC dialog. `test_installer.ps1` builds a unique
installer and exercises process waiting, Unicode paths, shortcuts and uninstall
in private temporary directories. `test_update_progress_ui.ps1` must run in an
interactive Windows session and receives a versioned fixture EXE that it never
launches. None of these tests modifies an installed BobTV or its user database.

On the first launch of a release build, BobTV checks the current user's
redirected Desktop and the shared Desktop for a shortcut targeting this
installation. If none exists, it creates BobTV.lnk on the current user's
Desktop. A stale BobTV.lnk targeting an older BobTV executable is updated;
unrelated shortcuts are preserved. The update worker repeats the check after
installing a new version. Shortcut failures do not prevent playback or updates.
