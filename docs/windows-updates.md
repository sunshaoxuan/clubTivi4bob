# Windows automatic updates

The current public API provides `GET /releases.json` and
`GET /downloads/{filename}`. Settings can list releases and download a ZIP,
validating the actual file with SHA-256. The public API does not yet define
version comparison or automatic installation. Automatic polling of the retired
`/updates/latest.json` endpoint is disabled. The installed application does not
need GitHub access.

## Legacy mirror contract, retained for a future compatible server

The HTTPS JSON manifest has these fields:

    {
      "schema": 1,
      "version": "0.9.2+54",
      "archive": "https://bobtv.briconbric.com/updates/BobTV-v0.9.2-bob.10-windows-x64.zip",
      "sha256": "64 lowercase hexadecimal characters",
      "bytes": 64963783,
      "publishedAt": "2026-09-27T00:00:00Z"
    }

The ZIP must use the same HTTPS host, contain a BobTV root directory, include
BobTV.exe and data/app.so, and have an executable file version equal to the
manifest version. Its SHA-256 and byte count must match the manifest. The app
rejects redirects and archive URLs outside /updates/.

The provisional uploader accepts HTTPS PUT with a bearer token stored in the
BOBTV_MIRROR_TOKEN environment variable. It uploads the archive first,
downloads it again to verify SHA-256, and publishes latest.json last. The
upload adapter can be changed if the eventual server uses another authenticated
method. Publication must fail if mirror verification fails.

Advance lib/core/app_version.dart and pubspec.yaml together for every release.
Build the Windows ZIP from that version, run the ZIP integrity check and a
Windows launch test, then publish the mirror manifest.

## Installation and recovery

The independent worker downloads while the player is open. It continues after
the player closes, then backs up the complete previous application directory
under the user's LocalAppData/HotelTV/Update/Backups directory and installs the
new files. Runtime preferences and playlists remain in the user data directory.

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
