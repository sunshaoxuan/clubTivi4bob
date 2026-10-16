# BobTV website and API

This directory is the canonical source for `https://bobtv.briconbric.com`: the public site, the local release mirror, the video-source APIs, and bounded diagnostic intake. The Flutter application lives in `lib/` in this same repository. Existing GitHub release assets are mirrored to the server; users download from the BobTV host. Deploy `route_identity.py` alongside the inventory and catalog publisher. [Route identity](ROUTE_IDENTITY.md) describes global deduplication and permanent retirement across rediscovery and URL spelling variants.

The product page describes BobTV as a Windows and macOS desktop TV player. Windows 10 compatibility requires client-side validation before publishing a support claim.

The hero image is a user-provided crop of the BobTV simplified-mode interface with playback and channel listings visible. Product, downloads, and diagnostic uploads are separate pages. Source reporting is API-only.

The product, download and diagnostic pages share a dark navy and peach visual system and the supplied real player screenshot. Build `1.0.6+90` moves source discovery and AI execution to the server and routes desktop media, guide and logo access through the HTTPS gateway. Regional rankings use observed playback feedback; relaying alone cannot guarantee Mainland China availability. It fixes Windows fullscreen window chrome and maximization restoration while retaining redesigned settings, desktop picture-in-picture, the three-programme text guide, mouse-accessible exit, Setup, Unicode paths and shared catalog synchronization. Protected Windows installations require administrator-authorized Setup upgrades; writable per-user installations support background updates. Diagnostic summaries remain optional and off by default.

`templates/` and `locales/` preserve the four-language pages used by the deployed rendering runtime. Release content deployment updates these files and the static fallback pages while preserving the deployed API, localization and device-count services.

## Website maintenance with every release

Publishing installation packages also requires a content review:

1. Update the homepage feature descriptions, current version and version history against the implemented and tested behavior.
2. Update installation, first-launch and update instructions for both Windows and macOS. Keep one release row with three platform downloads.
3. Review diagnostic and privacy explanations; distinguish shared public channel records from personal local data and optional diagnostics.
4. Update the API and synchronization documentation when the contract changes. Run `python -m pytest website/tests -q` and inspect desktop and mobile layouts.
5. Back up and deploy the HTML/API runtime alongside the verified release mirror. Check live page copy, download links, all three update manifests and the channel catalog.

The package mirror alone does not update the static feature descriptions.

## Endpoints

The shared installation inventory is implemented separately from the legacy
opt-in reviewed-source directory. Every installation contributes public TV
metadata in batches through `POST /api/v1/channel-catalog/inventory`.
`GET /api/v1/channel-catalog/blocked` distributes durable global retirement
records. `POST /api/v1/channel-catalog/events` receives idempotent additions,
metadata and category edits, health observations, deletions and retirements.
Clients flush their durable queue every 15 seconds and check snapshot revisions
every minute. Deploy `bobtv-catalog.service` and `bobtv-catalog.timer` to verify
pending media and atomically publish fresh preclassified snapshots every five
minutes. Client success reports prioritize verification but do not directly
publish routes. The legacy `/source-candidates` workflow below remains private
and manual; it does not govern the new shared channel inventory.

- `GET /api/v1/channel-catalog/manifest`: version, counts, snapshot path, byte length, and SHA-256 for a preclassified channel catalog. An unpublished catalog returns a zero-count manifest so clients keep local sources. Conditional `If-None-Match` requests are supported.
- `GET /api/v1/channel-catalog/snapshots/{sha256}.json.gz`: immutable compressed catalog. Previous snapshots remain readable while a client completes a download across a manifest change. The publisher validates stable category, channel, and route IDs, category parents, and reviewed public URLs before atomically replacing the manifest. Clients verify the byte count and SHA-256 before importing while preserving local favorites, retired routes, and subscriptions.
- `GET /`: product view. `GET /downloads`: release downloads. `GET /diagnostics`: manual diagnostic upload. There is no public source-report page or contribution summary.
- `GET /releases.json`: locally published manual-download manifest.
- `GET /downloads/{filename}`: local ZIP or DMG bytes, with range support from `FileResponse`. Never redirects to GitHub.
- `GET /updates/{windows-x64|macos-x64|macos-arm64}/latest.json`: independently verified automatic-update manifest for one desktop platform, or 404 before its first approved package. `GET /updates/files/{filename}` serves current and previously approved archives so in-progress downloads survive a manifest change.
- `POST /api/v1/logs`: `Content-Type: application/x-ndjson`, at most 1 MiB and 5000 lines. Every line is a JSON object with `time` and `event`; only `time`, `event`, `source`, `fatal`, `uptimeSeconds`, `rssBytes`, `maxRssBytes`, and `platform` are accepted. Successful responses return `201` and a SHA-256 `id`; repeated bodies return `200`. Invalid payloads return `415`, `422`, or `413`. Requests are capped at 300/hour per origin-visible IP with `429` and `Retry-After`. Behind Cloudflare this may group visitors by edge address; the proxy overwrites untrusted incoming `X-Forwarded-For`.
- `GET /api/v1/sources`: reviewed public HTTPS playback URLs and counts of distinct anonymous reports received in the last 30 minutes. `Cache-Control: no-store`. An empty catalog is valid. Counts are untrusted client feedback, never independent availability verification.
- `POST /api/v1/source-reports`: JSON with exactly `sourceId`, a stable client-generated 64-character lowercase hexadecimal `fingerprint`, and boolean `playable`. Maximum 512 bytes. Only IDs in the reviewed catalog are accepted. `202` means the observation was stored, `404` means unknown ID, `413`/`415`/`422` reject invalid input, `429` has `Retry-After`. Reports are deduplicated per source/fingerprint/5-minute bucket, expire after 30 minutes, and are capped at 100,000 live rows and 3,600 attempts/hour per origin-visible IP. No playlist URL, token, stream headers, raw MAC address, or account data may be reported. The server stores only the SHA-256 digest of the fingerprint. Client observations cannot establish trust in a source.
- `POST /api/v1/source-candidates`: explicit opt-in contribution of a public HTTPS playback URL for private review. JSON fields are exactly `name`, `url`, `device` (`Windows`, `Android`, `iOS`, `macOS`, `Linux`, or `Other`), `fingerprint` as above, and `consent: true`, maximum 4 KiB. The server records source name/URL, IP, coarse device category, and country code when a trusted Cloudflare edge supplied it. Only the SHA-256 digest of the fingerprint is stored, allowing continuity across IP changes during retention. It rejects credentials, query parameters, fragments, IP literals, custom ports, and private hostnames. Pending sources are not served to other clients and are removed after 14 days unless resubmitted. No public read endpoint exposes candidates or contributor attribution. Thirty attempts/hour per visible origin and 10,000 live records bound abuse. The `cloudflare_ranges.json` trust list comes from Cloudflare's published IP ranges and needs maintenance when Cloudflare changes them.

The reviewed catalog lives in `sources.json` and is versioned with the site. Entries require unique lowercase IDs, names, and publicly distributable HTTPS URLs without credentials, query parameters, fragments, IP literals, or custom ports. The server never probes client-supplied URLs and never publishes client-submitted URLs automatically. Review pending records through private server access, confirm redistribution permission and playback from relevant networks, then add approved entries to `sources.json` through version control. An empty catalog is safer than advertising an unverified source. Client integration is specified in `SOURCE_INTEGRATION_PROMPT.md`.

For faster first launch, prepare a separate preclassified channel JSON file with the schema in `API.md`, then run `BOBTV_DATA_DIR=/var/lib/bobtv python publish_channel_catalog.py /path/to/reviewed-channel-catalog.json` as the `bobtv` user. Its manifest and compressed snapshots live in `/var/lib/bobtv/channel-catalog`. The reviewed source endpoint remains independent. The publisher refuses empty or invalid catalogs and does not fetch GitHub sources on its own.

No client authentication material is embedded in a public application. The API is a public, rate-limited intake. Caller identity is not established by the returned digest. Uploaded logs are private on disk, have no public read route, and are pruned after 14 days when another upload arrives. Server storage is capped at 512 MiB. Schedule `prune.py` daily so retention also runs during idle periods.

The browser and desktop client project local logs into the API's bounded summary schema before sending. Desktop users can upload a summary manually or enable optional automatic summaries, which are disabled by default and scheduled every six hours. Requests retry rate limits and transient server errors with bounded backoff. Credentials, full stream URLs, arbitrary exception text and dump files are excluded from these summaries. Shared channel synchronization is independent of this optional diagnostics setting.

The app-facing API contract is `API.md`. Implementation prompts for source integration and diagnostics are `SOURCE_INTEGRATION_PROMPT.md` and `CLIENT_INTEGRATION_PROMPT.md`. Historical infrastructure verification is archived at `docs/operations-2026-09-27/receipt.md`.

## Resumable public catalog audit

`deploy/bobtv-catalog-reclassify-20261015.service` persists the existing
`20261015-ai-reclassification` run across server restarts. Install it under
`/etc/systemd/system/` and enable the same unit name. It runs as `bobtv`, uses
the protected `/etc/bobtv/ai.json` configuration, and limits CPU, memory and
tasks independently of the public API. Do not start a second worker for this
run, reset its JSONL audit, or add `--retry-reviews` during routine recovery.

Progress is recorded in
`/var/lib/bobtv/reclassification/20261015-ai-reclassification.status.json`.
Catalog refreshes can add targets or replace route-set identities. Staging
counts only identities in its current target set; older audit records remain
in the append-only file and appear separately as `historicalAuditRecords` and
`historicalAuditCounts`. Validate `completedChannels + pendingChannels ==
targetChannels` and `classified + needsReview + manualPreserved ==
completedChannels`. The unique audit-record count equals `completedChannels +
historicalAuditRecords`, with each global result count likewise including its
historical count. A catalog expansion can lower the completion percentage
without losing audit records. AI budget waits are normal and preserve progress.

The installed audit unit selects `--model gpt-6-luna --upstream-limits`.
Only this operator-run audit bypasses local hourly/daily request-count budgets;
other workers retain their existing protection and configuration. Audit calls
do not consume their local counter. Each request handles at most five channels,
with one AI request in flight and a two-second gap between successful batches.
New audit decisions record the actual requested model; existing records remain
unchanged. The Luna request uses JSON mode and no reasoning effort for this
fixed-schema task.

`waiting_for_upstream` preserves all progress counts and records a safe
`errorCode`, `retryAttempt`, `waitSeconds` and `nextRetryAt`. Temporary 429,
5xx and network failures retry the same uncommitted batch with exponential
backoff and jitter, respecting `Retry-After` as a minimum. Successful batches
reset the backoff. Authentication and explicit billing/quota errors stop with
exit code 2 and `state=failed`; `RestartPreventExitStatus=2` prevents an
unattended restart loop. No exception body or credentials enter the status.

`ready_to_apply` is not a publication receipt. Advance dependent work only after
`state=complete`, a nonempty `publishedCatalogVersion`, and verification of the
published manifest and snapshot. Completed status uses `channelsReviewed`
instead of staging progress fields. Later routine catalog versions do not
invalidate a verified completion receipt.

## EPG source validation checkpoint

`epg_ingest.py` is the initial server-side validation stage, not a complete EPG
discovery or publication service. The public catalog audit completed on
2026-10-16 with 6,939 reviewed identities. Its immutable publication receipt and
both public node snapshots were verified before this stage began.

The independent `bobtv-epg-validator.timer` runs a bounded oneshot worker. Each
run probes at most one due XMLTV source, serially, and checkpoints source health
plus append-only attempt evidence in `/var/lib/bobtv/epg/epg.sqlite3`. Successful
sources follow their reviewed six-hour refresh interval. Failures use
exponential backoff, jitter and any longer upstream `Retry-After`; idle timer
runs do not download or parse the source again. Existing API workers are not
restarted or modified by installing this validator.

Requests reuse pinned public DNS connections, require reviewed HTTPS URLs and
exact redirect destinations (or an explicitly reviewed same-origin versioned
XMLTV path policy), and enforce time, compressed and decompressed
size bounds. XML declarations with entities/DTDs and unsupported encodings are
rejected. Programme timestamps must include explicit UTC offsets. Missing end
times can only be derived from the next unambiguous start for that same source
channel, with the inference recorded. Conflicting channel IDs are quarantined,
overlapping/conflicting programmes are rejected, and historical-only/empty
HTTP 200 responses are recorded as failures without replacing last-good health
evidence. This diagnostic stage stores quality counts, not programme schedules.

Both existing client defaults remain `publicationAllowed: false` in
`epg_sources.json`: their separate programme-data redistribution permissions
have not been established. There is no public EPG version from this worker,
no new channel mapping, and no client hot-sync capability yet. At the audited
publication baseline, 4,907 of 6,939 channels carried an EPG ID; these are metadata
candidates, not verified schedule coverage. Routine catalog refresh continues,
so every coverage checkpoint records its catalog version and denominator.
The next stage must implement reviewed data permissions,
exact identity mapping, catalogue discovery/replacement queues, transactional
last-good programme storage, immutable publication and main/relay consistency,
then client background version/import integration and the full acceptance tests.
Only the primary server may write the future EPG programme database.

The next deployed increment, `epg_discovery.py`, records internal identity
candidates in the same primary `epg.sqlite3`. Its independent timer processes
continuous batches of at most five catalogue channels within a 25-second work
budget, then checkpoints. It prioritizes explicit CN/HK/MO/TW metadata and
public playback evidence, without collecting private favourites. New/changed
identities and source identity drift requeue affected work; changing only a
catalogue timestamp or programme title does not redo existing identity reviews.
Interrupted leases recover after 120 seconds. Unmatched identities retry after
six hours or immediately when source identity metadata changes.

Programme-window expiry alone does not change the identity-review generation.
Freshly fetched channel-name/context evidence remains diagnostic metadata when
its last observed programme ends. The existing twice-refresh fetch-age limit,
persistent-failure exclusion, supersession and grant/attribution checks remain
active. This prevents clock-only full-catalogue rescan churn. Programme storage,
publication and coverage continue to reject expired or missing current/future
slots independently; metadata candidates never establish a live schedule.

Initial source identity metadata can be validated from the existing local
egress cache, preserving its original fetch time, with no new upstream request.
Subsequent source probes update identity metadata transactionally. Ambiguous
source IDs remain quarantined. Exact IDs/full names are recorded as candidates,
never approved mappings: source geography, regional/delay versions and programme
data rights still require verification. CCTV number/plus conflicts and delay
conflicts are excluded. Persistent source failures retire its active proposals
and permit alternative candidates, with earlier evidence retained. This is
candidate rediscovery, not deployed programme-source failover.

`bobtv-epg-discovery.service` has no network access, does not call AI, and cannot
publish schedules or modify client mappings. `epg_source_reviews.json` records
excluded/reference-only candidates separately from the enabled health registry.
EPG.PW was excluded from public server redistribution after reviewing its current
terms at `https://epg.pw/terms.html`; no programme feed was downloaded from it.

The unshipped shared client importer now validates non-empty, non-expired source
data before a transaction replaces that source's programmes, channel metadata
and refresh timestamp together. A write error rolls back all three; another
private source is preserved. The regression tests exercise consecutive imports,
empty/stale data, wrong-source identities and insertion rollback. This is not
the background server-version receiver, and it does not remove the legacy
four-hour source refresh shortcut. Version polling, checksum validation, UI
invalidation and Windows/macOS/Android real-device playback tests remain pending.

`epg_store.py` adds staged programme storage and publication primitives. They
require an explicit programme-data grant and context-reviewed exact mapping;
the diagnostic registry does not create either. At most five approved catalogue
identities are ingested per call. Fetch receipts, source and catalogue identity
fingerprints, UTC offsets, raw source timestamps, derived-stop evidence,
confidence, data-use evidence and original channel names are retained. A stale
target inside an otherwise healthy feed does not erase its last valid schedule.
Semantic deduplication prevents unchanged programme data from creating versions.

Publication creates the immutable gzip snapshot before contacting both fixed
public nodes to verify its checksum and decoded programme content. A short
database write lock protects final permission/identity revalidation and atomic
activation. `epg_publication_audit`, the full manifest receipt in
`epg_publication_manifests`, and the sole visible pointer in
`epg_publication_state` commit in ONE SQLite transaction. No mutable filesystem
manifest controls public visibility. Audit insertion, pointer update or COMMIT
failure rolls back the new activation; concurrent readers see the old committed
version. Timeout, snapshot write and checksum failures likewise keep it intact.
The tests exercise two successive synthetic versions and failure/recovery;
these are isolated fixtures, not live programme publication acceptance.
`epg_catalog.py` provides no-store dynamic metadata and immutable content reads.
It uses a read-only connection to the primary EPG database and verifies the
committed audit link and snapshot availability/hash. Broken receipts or content
return a bounded 503 instead of advertising unusable data. Snapshot checks are
cached only by filesystem revision, not by the dynamic version query.
`epg_api.py` is deployed as the independently enabled `bobtv-epg-api.service`,
bound to loopback port 8918 with read-only data mounts, 256 MiB/10% CPU limits,
16 concurrent requests and automatic recovery. A dedicated Nginx location routes
EPG reads there. The existing main API process and its actual deployed app file
were kept unchanged. Graceful Nginx reloads preserve the master process.
The cndrp cache change adds only immutable EPG snapshot paths; dynamic manifest
queries bypass caching. It still forwards to the primary authority and creates
no relay EPG database. No data grants, mappings or public programme version were
created. The API currently reports an explicitly unpublished zero-count version.

The additional Hong Kong XMLTV candidate is diagnostic-only. Its initial
ccnode request timed out after 8.22 seconds; this actual failed attempt was
checkpointed before enabling bounded retry in the existing validator. A single
timeout is transient, not a permanent source-retirement decision. A later
bounded diagnostic verified fresh schedules for 176 source identities. The
reviewed configuration revision accepts only HTTPS, the unchanged origin and
country filename, and one 32-lowercase-hex directory under `/files/`. Host,
country-file, scheme, port, credential, query, fragment and path changes fail
closed; DNS pinning, four-hop, eight-second I/O and size limits still apply.
The original source row, attempts and last-good evidence are retained, with an
idempotent `source_replacements` audit relation. Superseded configurations no
longer supply identity proposals. Programme-data permission and exact catalogue
identity context remain unverified, so the health revision cannot publish.

The Taiwan educational-radio dataset `https://data.gov.tw/dataset/26185`
explicitly identifies its programme-data license. Its Open Government Data
License v1.0 allows distribution/adaptation with attribution, separately from
scraper code rights. However, the exact published endpoint returned only twenty
rows dated 2026-10-12 during the 2026-10-16 live server check, without an explicit
timezone field. It remains review evidence only, outside the enabled worker
registry. Old dated rows are never projected onto current/future days.

### Staged shared client EPG version receiver

`epg_tvmaze.py` is a separate diagnostic adapter for the provider's documented
country/date JSON endpoint. The API explicitly licenses programme metadata under
CC BY-SA 4.0. Attribution, a license link, modification notice and ShareAlike
must reach the eventual public derivative and client before publication. The
adapter fixes the HTTPS host/path, accepts only strict country/date scalars,
reuses pinned public DNS and rejects redirects with bounded time/size limits.
It requires the network country/timezone, explicit episode airstamp, matching
local airdate/time and an explicit positive episode runtime. Show-level default
runtime is never substituted. End time is derived only from that episode's
explicit start/runtime, with both facts recorded. Web-only records, identity or
slot conflicts and overlaps are rejected. Sparse episode gaps stay empty.
The first live server probe found 27 future GB episodes across 11 networks,
zero current-and-future networks at that instant, and empty HK/TW responses.
CN records could not safely form a usable schedule. Exact name/country hits are
review candidates only. The diagnostic validator now dispatches three reviewed
JSON configurations, CN, GB and US, through the same serial one-source-per-run timer.
Only the fixed provider host/path and strict country/date parameters are used;
the date follows the reviewed calendar timezone. The provider's one-hour cache
interval bounds successful/partial checks and HTTP-200 empty/invalid-data retries.
Network failures retain exponential backoff and longer upstream Retry-After.
Future-only/current-only sparse data is explicitly `partial`, never full current
and future coverage. Country/timezone context is stored in a separate internal
identity table and rules out cross-country same-name proposals. Identity-context
changes requeue discovery, while programme-only changes do not. Legacy egress
XMLTV cache is never parsed as JSON. All diagnostic configurations have public distribution
disabled; the worker creates no grants, approved mappings or programme rows.
TVmaze's generic Syndication bucket (network 72) is excluded because it describes
distribution across independent stations rather than a single broadcast feed.

Publication code additionally requires explicit attribution metadata for
CC BY-SA data grants: source credit/link, license link, transformation notice and
ShareAlike flag. Relevant attributions enter the immutable snapshot's semantic
version and the final publication revalidation fingerprint. Missing attribution
or a mid-publication change prevents activation. JSON ingestion can preserve the
source episode URL and actual fetched country/date URL alongside normalized UTC
provenance. Following a separate live review of the provider's programme-data
license, explicit GB and US data-use grants and attribution records are installed.
These grants alone neither approve a catalog channel identity nor cache or publish
programmes. Exact regional and delay-variant mappings remain unapproved.
Discovery reads current explicit grants separately from identity evidence. The
diagnostic permission flag is true only when the grant matches the source URL,
is not revoked, and its evidence and required attribution remain valid. A license
statement in the source registry alone cannot set that flag. Permission/credit
changes enter a review-generation fingerprint and append a fresh bounded review;
prior identity audits remain intact. Even with data rights verified, candidates
retain `contextVerified=false` and `automaticallyApplied=false`. No mapping
confidence is raised by a data-rights grant.
Client attribution rendering
is implemented locally and remains unshipped. Real public publication and
end-to-end acceptance testing remain unfinished.

`epg_schedule_worker.py` now runs through the independently enabled
`bobtv-epg-schedules.timer`. Its deployed unit has `PrivateNetwork=true` and makes
no upstream requests. The existing serial validator hands off a checksummed,
bounded private payload only when BOTH an explicit programme-data grant and a
current exact channel mapping approval exist. Unapproved sources stay metadata
only. One 8 MiB maximum file per approved source is atomically replaced with
0600 permissions inside a 0700 cache directory, leaving last-good programme
rows independent of raw fetch/cache failures. Source fetch hashes and times
must match before ingestion. A shared validator lock prevents duplicate work.

Each schedule run processes at most five approved channels from one source.
Per-input checkpoints skip unchanged completed work, killed tasks retain a
resume lease, transient local failures back off and insufficient coverage is
rechecked without inventing programmes. Revocation, identity drift, stale
fetches, path escapes and cache corruption fail closed. The worker records real
verified/current-future coverage and coverage decline. It creates no grants or
automatic mappings. The deployed publication flag remains OFF and no live
programme snapshot is published. The read-only public API is active and returns
an unpublished version. The optional
two-node publication path has synthetic fixture tests only; it is not enabled
by the new timer. Before real publication, finish permission and identity review,
grant-change consistency and real programme validation, then verify two real
automatic versions, both nodes' programme content and all platform playback
acceptance. Local transaction failure-injection tests are complete; they are not
live programme acceptance evidence.

`ServerEpgSyncService` and `server_epg_snapshot.dart` add a source-only shared
client receiver with a five-minute version polling default. The receiver checks
dynamic metadata with no-cache/no-store request headers and downloads only a
changed version from the fixed BobTV snapshot path. Compressed SHA-256 and size,
expanded size, strict UTF-8, version/counts, exact channel/source identities,
UTC intervals, overlap and per-channel current/future coverage are validated.
Decompression and parsing run in an isolate in production. Programmes, channel
metadata, exact-identity evidence and the installed-version receipt commit in
one database transaction. Invalid data or interrupted imports retain the cache.
Manual mappings and private sources are untouched; a disabled managed source
stays disabled. The managed source bypasses the legacy XMLTV four-hour gate.

The staged core supports periodic checks and foreground/reconnect triggers,
coalesces concurrent requests, and respects exponential retry and Retry-After.
It exposes cache expiry in its status. Twenty new isolated receiver/HTTP tests
cover consecutive automatic versions, cache avoidance, corruption, offline
retention, retry, rollback and source isolation. These are synthetic local tests.
The unshipped application entry point now starts the receiver through
`ServerEpgRuntimeHost`. Lifecycle resume, desktop focus and disconnected-to-online
events trigger checks while respecting the receiver's retry deadline. A compact
non-interactive cache warning exposes temporary cached use and expiry without
altering the video surface. Existing installed clients do not gain this logic
until their first upgrade to a build containing it.

`ServerEpgBinding` now preserves each public route's complete catalog identity
fingerprint during catalog import, with a one-time metadata backfill on client
upgrade even if the catalog version is unchanged. Its sorted UTF-8 JSON hash
matches the server across full channel ID, name, EPG ID, country and region.
Only an exact fingerprint and unchanged local route context may create a server
mapping. Either catalog-first or guide-first arrival is supported. Manual,
locked and other-source mappings remain untouched. Automatic server mappings
are invalidated on identity drift, and unchanged bindings cause no rewrites.
Managed guide channels are excluded from legacy mixed-source fuzzy matching
and name/call-sign fallback indexes. Sixteen isolated tests cover these guards,
including catalogue-write rollback and preservation of playback route rows.
This linkage remains unshipped. `EpgUiRefresh` now coalesces EPG-table invalidation
for the channel cards/strip, full guide and fullscreen current/next programmes.
It never invokes a player operation. Fullscreen reads the latest exact mapping,
invalidated managed IDs cannot fall back to stale navigation context, and query
generations reject late results. The guide refreshes unchanged-ID rows on data
revision and retains its horizontal time position. Eight additional runtime and
widget tests cover lifecycle/reconnect triggers, coalescing, failure recovery,
transactional cache retention, live mapping lookup, cache warnings and a running
guide receiving changed programmes without recreating its screen or scroll.
These are isolated tests, not Windows/macOS/Android physical playback acceptance.
Live automatic publication, full real-data client integration, all platform
physical tests and the first client release remain unfinished.

The unshipped receiver now validates `dataAttributions` against each included
source and each programme's `provenance.dataLicense`. CC BY-SA 4.0 data requires
the source credit, HTTPS source/license URLs, a modification notice and the
ShareAlike flag. Missing, duplicate, unrelated or contradictory metadata rejects
the entire new snapshot. Credits and the guide/version receipt commit together
in `server_epg_attributions`; failed imports retain the old credit and guide.
The auxiliary table is created idempotently on database open without resetting
private sources. Cached credits load before network access and survive an
offline app restart. Settings > EPG > 服务器节目表署名与许可 shows the current local
source, license, modification notice and selectable URLs. It does not fetch
those URLs. An open credits view receives version changes without recreating
the underlying screen or its scroll. This code has local automated coverage;
it has not been released or installed on any user's device. The server's
attribution-aware store is deployed, with public publication still inactive.

`epg_publish_worker.py` is a separate bounded publisher, paired with
`bobtv-epg-publisher.service` and its persistent timer. It only reads approved,
exactly mapped programme rows from the primary EPG database and verifies the
prepared immutable snapshot from both fixed BobTV nodes before atomic activation.
It does not fetch upstream schedules or create source/mapping grants. No-data
runs record `waiting_for_approved_programmes` without making public HTTP requests
or activating a version. Attempts, interrupted leases, safe errors and retry
deadlines are durable; upstream Retry-After survives node verification failures.
An unchanged snapshot is not downloaded again. Live publication rechecks actual
wall-clock coverage after node validation, so programmes that expire during the
request cannot pass activation using the earlier time. Local fixture tests cover
two versions, failure retention and recovery; real-data consecutive publication
and three-platform physical hot-update acceptance remain outstanding.
Full permission, provenance and programme preflight scans run before the write
transaction. Activation compares the same connection's SQLite `data_version`
and `total_changes` tokens under `BEGIN IMMEDIATE`; any intervening write rejects
the new activation. A precomputed conservative current/future coverage deadline
also rejects clock rollback or expiry at the final boundary. Only the audit,
receipt and sole visibility pointer are written in that short transaction.
Synthetic concurrency tests cover rollback-journal and WAL modes; their fixture
channels and programmes never count toward real coverage.

`epg_coverage.py` supplies read-only coverage statistics for discovery and
programme workers. One SQLite savepoint keeps the catalogue, current data-use
grant, exact mapping, provenance and activation receipt in a consistent view,
without schema migration or data writes. Candidate names and source-level
episode totals do not count as approved catalogue mappings. Stored current and
future programme coverage follows the publisher's provenance checks. Public
coverage additionally reads the sole active immutable snapshot, verifies its
size, checksum and semantic version, and checks current identity, attribution,
provenance and programme windows per channel. A valid earlier publication can
still count while a newer programme version awaits activation. Orphan,
unavailable, corrupt and expired snapshots cannot inflate public coverage.
These local file checks supplement the publisher's two-node receipts; heartbeat
checks still verify the actual main and relay responses separately.

The programme-store approval check also revalidates the current source address,
permission evidence URL, programme-data licence and required attribution before
raw cache handoff, ingestion or a new publication. A retained approval row cannot
authorize a changed source URL, corrupt credit record or missing ShareAlike
notice. Invalid reviews fail closed without erasing the last-good programme rows
or publication receipt. Synthetic mutation-and-recovery tests exercise these
paths independently of candidate-name confidence and preserve mapping locks.

### Bounded persistent provider discovery

The XMLTV parser accepts only the fixed prolog reference `<!DOCTYPE tv SYSTEM
"xmltv.dtd">` (either quote style) by removing it before parsing. It never loads
or resolves that DTD. Internal subsets, entities, other system/public references,
multiple declarations and non-prolog declarations remain rejected. The original
wire hash is retained; quality records document removal without DTD resolution.
Generic/JSON decoding continues to reject every DOCTYPE.

`epg_source_discovery.py` persists country jobs and append-only discovery audits
in the existing primary EPG database. Its independent systemd timer runs every
two minutes, requests at most one fixed TVmaze country/day endpoint per worker,
and shares `worker.lock` with source validation and programme ingestion. The
reviewed country calendars are HK, MO, TW, FR, CA, JP, DE, IT, GR, KR, AU, NZ,
ES and NL. The calendar selects the request date only; each episode is still
validated against its explicit network timezone and broadcast timestamp.
Country calendars never establish a local or delayed feed edition. Only
countries actually present in the public catalogue are queued, with public
playable routes and CN/HK/MO/TW jurisdiction priority. Already configured
TVmaze countries are excluded to avoid duplicate fetching. Existing manual
diagnostic cache windows are retained as initial cooldowns, never represented
as successful automatic fetches.

An hour is the minimum retry/refresh interval. Repeated failures back off up to
24 hours; HTTP 429 honours upstream Retry-After and pauses other TVmaze country
requests, including the existing validator. Other providers retain their own
schedules. Interrupted leases and last-good source metadata survive restarts.
HTTP 401/403 requires review. New or removed public countries reconcile
idempotently without deleting old job or audit rows. No private favourites are
read. Source URLs cannot come from catalogue text, and the existing pinned
public-DNS, no-redirect, wire/decompression limits and timeouts remain in force.

This revision supports one provider's candidate discovery and continuous
validation only. It creates no data-use grant, mapping approval or publication.
Raw programme caching still requires an existing valid grant and exact mapping.
New source identities may change the identity-review generation legitimately;
programme expiry alone does not. Additional provider adapters and verified
cross-provider replacement remain necessary. Country diagnostic counts and
candidate-source health never count as public EPG coverage.

`epg_source_recovery.py` adds a persistent metadata-only recovery queue to that
same bounded worker. Three consecutive failures, three partial probes, expired
last-good coverage, or overdue refreshes trigger review. A single temporary
failure retains the ordinary retry path. Each pass evaluates at most five
sources and rechecks an unchanged recovery job no more often than every five
minutes; unchanged evidence does not append duplicate audits. Country search
scopes for existing XMLTV entries are bound to their reviewed URLs and never
establish exact channel or regional identity. Candidate alternatives must have
a successful, unexpired bounded probe from a different provider, and retain
their separate data-rights state. This queue makes no additional network
requests, approvals, source replacements or publication writes. It preserves
last-good metadata and records recovery without deleting prior audit evidence.
It does not yet implement broader provider search or verified production
failover; those remain required before claiming automatic replacement works.

### Single-channel official schedule diagnostic pilot

`epg_cctv.py` is a source-only CCTV-2 pilot. The fixed HTTPS host/path, fixed
`cctv2` service identity and validated numeric day are the only request shape;
the generic production registry's query prohibition is unchanged. Pinned public
DNS, rejected redirects, a one-MiB wire limit, four-MiB expanded limit, bounded
read time and at most 256 rows limit the diagnostic. Exact source channel name
and official live-page URL must agree. Explicit Unix start/end pairs are retained
without filling gaps, inventing a terminal stop or accepting another CCTV number.
Empty, historical-only, conflicting, overlapping and wrong-day records cannot
establish current/future coverage. Absolute timestamps and the unverified source
calendar context are recorded separately from catalog identity approval.

A live one-channel check found 36 explicit epoch pairs for the current source
day; a separate staged diagnostic normalized 38 next-day records. Those source
counts are not approved catalog coverage. The pilot was subsequently installed
as `cctv2-official-diagnostic-v1` in the existing serial validator, with a separate
database backup and unchanged prior source configurations and audit rows. It
starts pending with no fabricated success and cannot fetch before the prior
manual probe's cooldown ends at 2026-10-16T16:25:56Z. Ordinary one-hour refresh,
Retry-After, failure backoff and last-good identity metadata use the existing
durable health database. Authentication failures require manual review and do
not retry automatically. Existing XMLTV cache bootstrap excludes this JSON
format. The recovery queue recognizes only its fixed CCTV-2/CN configuration,
without approving alternative feed equivalence.

The adapter creates no raw cache, programme rows, mapping, data-use grant or
publication. Forty-two pilot/worker fixture cases and the full backend suite
cover these boundaries, including script-mode lazy imports. Durable server
health and audit records verified the first automatic request beginning at
2026-10-16T16:26:06Z, after the prior manual cooldown. Its response for source
day 20261017 contained 38 accepted records, 8,704 bytes and one source identity.
The fetch-time result is partial, with future coverage only; the next ordinary
request is due no earlier than 2026-10-16T17:26:06Z. No raw payload, programme
row or publication was persisted. Introducing this source identity triggers a
new mapping-review generation while preserving earlier audit records. The
exact catalog feed, source calendar context and programme-data permission remain
required before any schedule storage or publication. Existing client builds
are unchanged.

## Release mirror

Build 1.0.6+92 adds explicit cross-category channel merging from the channel
context menu. Users choose an existing or new name and a destination category.
Public routes synchronize as one compare-and-swap event across all members;
duplicate endpoints are collapsed, and identity, provenance, health and
retirement survive the operation. Personal subscription URLs remain private.
The selected category displays its own loading state. Whole-catalog record
counts appear only in the sync badge. The catalog version checkpoint is stored
with the local database so restored or fresh databases cannot skip initialization.

The download page selects the latest verified installer independently for each platform and labels its exact version. A platform-specific release does not remove another platform's previous installer or advance its update feed. Release 1.0.6 provides Windows x64 Setup/portable packages and both macOS architectures, with server-side discovery, HTTPS media access, regional ranking and fullscreen fixes. Automatic update status is separate from the manual historical-release browser. Foreground update checks are throttled to 15 minutes in addition to startup and six-hour checks.

Current releases mirror Windows x64/ARM64 Setup and ZIP packages, both macOS
architectures' DMG installers and signed update ZIPs, and Android ARM32/ARM64/x64
APKs. Downloads are grouped by operating system, with CPU variants inside each
group. Automatic updates use separate platform feeds.

Run `python mirror_releases.py` in this directory with `BOBTV_DATA_DIR=/var/lib/bobtv`. It reads public GitHub release metadata and downloads each matching BobTV Windows x64 ZIP or Setup EXE and macOS DMG into private staging. Size, ZIP signature, and GitHub's SHA-256 digest where present are verified before manual-download manifest publication. A release can additionally contain `BobTV-update-metadata.json` with `schema`, numeric `version` and `packages` entries containing `platform`, `filename`, `sha256` and `bytes`. Mac packages also require a base64 P-256 `signature` over the exact ZIP bytes. The mirror checks that signature with the bundled public key before publication. Each listed package is downloaded and verified before its platform's `latest.json` is atomically replaced. Older releases without this metadata stay manual downloads. Mac packages must be physically tested on their target architecture; CI test artifacts remain outside the release feed. Downloads are served from the local filesystem. The server needs outbound GitHub access for mirror refreshes; visitors do not. Deploy `update-signing-public.pem` with the website runtime files. Keep its matching private key outside the site and repository.

Normal runs publish only the newest non-draft, non-prerelease release and merge
its verified files into the existing download manifest. Historical archives are
not opened or hashed again; previous platform feeds, approved downloads and
rollback history remain available. Use `python mirror_releases.py --tag v1.1.5`
to publish or supplement a particular tag. A full historical archive audit is
an explicit maintenance operation: `python mirror_releases.py --all`. It must
not block an ordinary new-version publication.

## Deployment

Install `requirements.txt` in `/opt/bobtv/venv`, deploy the runtime files from this `website/` directory to `/opt/bobtv/site`, create user `bobtv` and writable `/var/lib/bobtv`, then install the systemd service and timers. The `website/docs/` and `website/tests/` directories are source and verification artifacts, not runtime data. Before restarting a site version with the source registry, run `BOBTV_DATA_DIR=/var/lib/bobtv /opt/bobtv/venv/bin/python /opt/bobtv/site/migrate_source_reports.py` as `bobtv`. Before enabling candidate intake, likewise run `migrate_source_candidates.py` as `bobtv`. Both migrations create separate versioned databases and are idempotent; older code ignores the new candidate database on rollback. During first issuance use `deploy/nginx-bobtv-bootstrap.conf` and `certbot certonly --webroot -w /var/www/bobtv-acme -d bobtv.briconbric.com`. Replace the bootstrap with `deploy/nginx-bobtv.conf` after certificate issuance. Validate `nginx -t`, reload, and verify origin and Cloudflare TLS separately. The independent BobTV certificate leaves the shared `briconbric.com` SANs and renewal behavior intact. Do not publish the site until the release mirror and certificate both verify.

Run `python -m pytest website/tests` from the repository root with `fastapi`, `httpx`, and `pytest` available. Flutter checks remain `flutter test` and `flutter analyze`.
