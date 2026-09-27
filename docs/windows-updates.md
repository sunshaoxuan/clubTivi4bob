# Windows automatic updates

BobTV checks https://bobtv.briconbric.com/updates/latest.json after startup and
every six hours. When the mirror is unavailable, playback continues unchanged.
The installed application does not need GitHub access.

## Mirror contract

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
startups, the next launch triggers rollback and remembers the failed version
in skipped_versions.txt, preventing its automatic reinstallation.

The rollback worker keeps a small, URL-redacted failure report and attempts to
POST it to https://bobtv.briconbric.com/api/update-failures. The endpoint is
provisional until the upload service is configured. Memory dumps are not sent.
If the POST fails, the report remains queued on disk and is retried during
later update checks.

Automatic updates apply to writable portable Windows installations. A
read-only installation remains on its current version and records the failure.
