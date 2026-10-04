# Windows automatic updates

Release builds check `https://bobtv.briconbric.com/updates/windows-x64/latest.json`
on startup and every six hours. Foreground checks are additionally throttled
to once per fifteen minutes. A missing manifest is reported explicitly and means that no approved
automatic update has been published. The independent worker downloads a newer
archive while BobTV runs and installs it after the app closes. Debug builds do
not poll automatically. The installed application does not need GitHub access.

Checking immediately shows a spinner. Settings retains the actual result,
including up-to-date, network failure, and a skipped unhealthy version. Active
download or installation progress is not overwritten by another check.
Setup-managed installations show a separate administrator-required state and
a link to the download page. They are upgraded by running the new Setup with
administrator authorization; the portable ZIP updater does not elevate itself.

## Platform mirror contract

The HTTPS JSON manifest has these fields:

    {
      "schema": 1,
      "version": "0.9.2+54",
      "archive": "https://bobtv.briconbric.com/updates/files/BobTV-0.9.2+61-windows-x64.zip",
      "sha256": "64 lowercase hexadecimal characters",
      "bytes": 64963783,
      "publishedAt": "2026-09-27T00:00:00Z"
    }

The ZIP must use the same HTTPS host, contain a BobTV root directory, include
BobTV.exe and data/app.so, and have an executable file version equal to the
manifest version. Its SHA-256 and byte count must match the manifest. The app
rejects redirects and archive URLs outside /updates/.

The release workflow packages a `BobTV/` rooted ZIP and produces
`BobTV-update-metadata.json` containing the exact archive hash and byte count.
The site mirror verifies both against GitHub release assets before publishing
the platform manifest. Pre-existing releases without update metadata remain
available as manual downloads and do not trigger automatic installation.

Advance lib/core/app_version.dart and pubspec.yaml together for every release.
Build the Windows ZIP from that version, run the ZIP integrity check and a
Windows launch test, then publish the mirror manifest.

## Installation and recovery

The independent worker downloads while the player is open. It continues after
the player closes, then backs up the complete previous application directory
under the user's LocalAppData/HotelTV/Update/Backups directory and installs the
new files. Runtime preferences and playlists remain in the user data directory.

The update badge immediately animates while preparing the download, then shows
percentage and transferred bytes. Readiness is displayed only after package
verification. On exit, an independent native window shows download, verification,
backup, installation and completion. A completed update keeps that window visible
for 20 seconds and offers an Open BobTV button. Failure leaves the window open
with a readable error and a restart option. Closing this status window does not
cancel the update worker. Reopening BobTV observes a live task without duplicating it.

The native launcher supplies valid standard handles to the hidden PowerShell
worker and captures launch errors in `launcher.log`. Per-run status files bind
feedback to the version, run ID and process ID; missing acknowledgement and an
exited worker are reported rather than leaving a permanent new-version badge.
Installations affected by an older broken worker launcher need one manual
installation of 0.9.1+73 or later before subsequent automatic updates can work.

The Windows bootstrap records startup attempts before Flutter starts. After
the channel browser loads and remains up for 30 seconds, the startup marker is
cleared. A normal close also clears it. After three consecutive unclean
startups, the independent monitor triggers rollback immediately and remembers the failed version
in skipped_versions.txt, preventing its automatic reinstallation.

The rollback worker keeps a small failure record locally. It no longer sends
records to the retired `/api/update-failures` endpoint. Separately, users may
opt in to upload a restricted diagnostics summary through `POST /api/v1/logs`.
Raw logs and memory dumps are never sent by that path.

Automatic updates apply to writable portable Windows installations. A
read-only installation remains on its current version and records the failure.

On the first launch of a release build, BobTV checks the current user's
redirected Desktop and the shared Desktop for a shortcut targeting this
installation. If none exists, it creates BobTV.lnk on the current user's
Desktop. A stale BobTV.lnk targeting an older BobTV executable is updated;
unrelated shortcuts are preserved. The update worker repeats the check after
installing a new version. Shortcut failures do not prevent playback or updates.
