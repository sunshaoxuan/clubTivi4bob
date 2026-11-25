# Casting diagnostics

Opening the casting dialog creates a random session (`requestId`). Events remain
correlated through device discovery, selection, pairing, media commands, transport
state samples and relay traffic. iOS system-player entry is recorded, but the
system AirPlay picker does not expose its internal protocol diagnostics here.

The current desktop implementation records:

* DLNA SOAP actions, HTTP status, UPnP fault codes, request durations, and three
  transport-state samples spaced three seconds apart after command acceptance.
* LG WebOS connection and registration results, media format, action durations,
  numeric receiver errors when supplied, rejection and disconnect failures.
* AirPlay helper stages, command durations, timeout, process exit and explicit
  playing events where supported. Existing native sender diagnostics are
  forwarded through a strict projection. The remux relay reports fixed error
  categories and the first twenty receiver file requests.
* LAN relay access rejection, upstream HTTP status, first byte, progress every
  ten seconds and completion bytes/duration for the first twenty requests.
* Source codec identifiers when available from the local player, dimensions,
  audio sample rate and channel count. Unknown codecs remain `unknown`.

Device and stream identities use 32 hex characters from SHA-256. URLs, query
parameters, private device names, pairing PINs, keys, raw server responses and
video/audio payloads are excluded from these new events. No video is decoded
or transcoded for logging. Existing playback behavior is retained. A maximum
of 1500 events per dialog session bounds diagnostic write volume.

Command acceptance does not establish visible playback. `cast_command_accepted`
is distinct from `cast_dlna_state_playing` and `cast_airplay_playing`. WebOS
media-open acknowledgment alone cannot confirm that the TV displayed a frame.

## Automatic upload

The existing diagnostics consent and enabled preference remain authoritative.
While enabled, new casting events trigger an incremental sync after a ten-second
coalescing window. Idle polling delay is bypassed; network/server retry delays
and intermediate relay receipts are honored. Offline data stays in the existing
bounded outbox. The origin acknowledgment advances upload checkpoints. Existing
thirty-day retention and capacity limits apply. This is additional structured
metadata within diagnostics schema version 2; both node validators must be
updated before distributing a client with the additional fields.

Uploads and relay forwarding use gzip (`Content-Encoding: gzip`); the receipt
digest always identifies the original JSON bytes, so retries and receipts stay
stable across compression. Each batch is limited to 256 KiB both on the wire
and after expansion. Invalid, truncated and concatenated gzip streams are rejected.
Old clients can still send uncompressed JSON. The bounded server store currently
keeps validated JSON, while transfers and operator downloads are compressed.

Each new batch includes `terminalFingerprint`, reusing the app-scoped anonymous
client fingerprint. If platform identity initialization is unavailable, a stable
hash of the diagnostic installation ID is used. Raw machine identifiers are not
uploaded. Older pending batches retain their exact bytes and use installation ID
for attribution until new batches carry the fingerprint.

The application needs a new build before these client changes take effect.
Changing only the server cannot add logs to already installed clients.

## Private operator access

Run from the repository, with the existing operator SSH key:

```sh
python3 tools/diagnostics/cast_logs.py --after 0 --limit 30
python3 tools/diagnostics/cast_logs.py --download BATCH_DIGEST --output /private/tmp/cast-batch.json.gz
```

Listings include digest, stable anonymous terminal fingerprint, installation ID,
server receive timestamp, session IDs, event counts,
last event and failure count. `--after` is an inclusive Unix timestamp; retain
seen digests when scanning incrementally. Listings inspect at most 2000 recent
unexpired batches. A session may span batches. Download all matching batches
and order their events by timestamp. Downloads require authenticated SSH and
create a new `.json.gz` archive with mode 0600. Compression happens on the node
before transfer; the download tool verifies the original SHA-256 after expansion.
Use `--terminal FINGERPRINT` to select one terminal. No public payload-download
endpoint is added.

Deployment uses `tools/deploy_cast_diagnostics.py`, which checks the live schema
against the checkout's HEAD baseline, backs up the file, replaces only the
diagnostic modules and rolls them back if import or service checks fail. Its baseline
check intentionally refuses unrelated changes on either node.

## Validation for this change

* Flutter casting and diagnostic regression suite: 27 tests passed.
* Server diagnostic ingestion/relay suite: 9 tests passed.
* AirPlay diagnostic projection/rotation: 2 tests passed.
* Additional integrated test confirms that cast events wake an idle uploader,
  that disabling diagnostics stops uploads, and that HTTP 429 backoff survives
  further casting events.
* Both live node validators deployed with backups. Synthetic events marked
  `operator_smoke_test` received through origin and relay; the relay receipt
  advanced to `origin_accepted` and the batch appeared in the private listing.
  Private SSH download was verified with file mode 0600.
* Actual LG/AirPlay receiver failure reproduction and new client packaging
  remain separate acceptance work. No new application release was published.


## Compression and terminal attribution validation

The focused Flutter upload/sync suite passed 11 tests, and the server suite
passed 11 tests, including malformed archives, expansion limits and terminal
fingerprint validation. Static analysis of both modified client services passed.

Live synthetic probes with two distinct terminal fingerprints confirmed origin
and relay gzip ingestion, relay forwarding to origin, fingerprint-based listing,
and private gzip download with original-content digest verification. The
100-event synthetic batch measured 28,477 bytes before compression and 1,067
bytes after compression at the origin. This sample does not predict the
compression ratio of all user logs. Both nodes were deployed with backups;
client packaging and publication remain outstanding.
