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

### Exact-route identity metadata (2026-10-19)

The existing channel-first worker can enable `--exact-route-identity` for one
selected public radio channel per run. `epg_route_directory.py` queries only
Radio Browser's documented by-URL metadata endpoint, never its country-wide
lists, station homepages, click/vote routes or media. Exact catalogue URL equality
is required. Credentials, signed URLs, IP literals and ambiguous ports are not
sent. The fixed HTTPS destination uses pinned public DNS, no redirects or
compression, a 64 KiB bound and bounded connection/read checks.

This identity-only stage precedes the shared AI-admission wait. It retains
channel attempts and retry floors, respects active leases and protected/manual
mappings, rejects in-flight catalogue drift, and rotates recently checked tasks.
Metadata from the same route can be reused across separately selected targets
without another download, with each target's audit and country-conflict check
kept separate. Temporary provider failure uses shared exponential backoff so a
different channel cannot repeatedly request the same failing endpoint. Explicit
manual-action pauses remain respected. The normal batch stays at most five
channels and the deployed default remains three.

All records remain partial identity observations in the existing authoritative
database. Country disagreement is not an automatic correction. Full operator,
number, spoken language, regional/delay edition and classification review still
precede any programme search or data-use grant. This path cannot approve an
identity, create mappings/programmes, grant rights or publish EPG snapshots.
The follow-up evidence bridge attaches one current lookup, including an empty
result or failed check, to that same target's review packet before AI admission.
It retains the original fetch time and retry floors. Typed lookup records may
supply search wording, but cannot supply checked-page quotations or satisfy
the exact-route approval gate. Unresolved country conflicts remain blocked
after cache expiry until reviewed for a new/corrected identity. Negative checks
cannot become successful identity facts, and no evidence packet alone approves
a mapping or data-use grant.
Installation receipt and ordinary-timer activation evidence are recorded in
`docs/diagnostics/2026-10-19-epg-identity-funnel.md` separately from client-release
and physical hot-update acceptance. No client release or application restart is
required for this server-only stage.

### Target-bound technical identity pages (2026-10-19)

The generic path filter retains its news/login/media and identity-stage schedule
blocks. Two reviewed CHC technical pages with numeric CMS paths are admitted
only for the exact selected CHC家庭影院 catalogue ID, name, country, region,
epgId, category path and route-hash set. Any scope drift invalidates both the
research alias and path exception. Model-provided URL allowlists have no effect;
host restrictions, public-DNS validation, redirects, size and timeout limits
still apply. This does not allow sibling pages, programme endpoints or a whole
CMS domain. Checked text still needs target-context extraction and full identity
review; a footer company name or community playlist label alone cannot approve
a feed, licence, mapping or programme data. The 969-test EPG regression suite and
server memory smoke passed before the single-module deployment. The ordinary
timer loaded the update without API, service, client or device restarts; the
first three target-page checks were explicit bounded research, not an automatic
CHC search or identity approval.

The next increment binds the PTS channel-position table to one selected 公視
entity with its current null country and exact route. It does not fill TW from
the category or confuse the main service's cable/MOD position 13 with the
Taiwanese-language sibling at 14. The generic minimum-length name rule remains;
only the reviewed table's exact main-service phrase can supply a partial text
excerpt for this short label. Fetch and cache re-extraction carry the source URL
so the phrase cannot transfer to another page or target. Excerpts retain the
actual text. A footer, sibling number or bare short name does not qualify.
The 999-test EPG suite and server-memory checks passed, and the ordinary timer
loaded the three updated modules without restarts. The first real page check
preceded the phrase fix and returned no_selected_identity_text. Its bytes were
not retained and no second fetch was made, so post-fix same-byte live extraction
is still unverified. Complete identity, programme searches, grants and mappings
remain separate, unapproved steps for this target.

### Current delivery boundary (2026-10-17)

The shared server-version receiver, background runtime, exact catalogue binding,
EPG-only UI refresh and attribution view are included in the separately
authorized 1.1.6 release. An older installed client still needs its first
upgrade to gain those capabilities. The paragraphs below retain incremental
implementation history; their earlier "unshipped" and "next stage" descriptions
do not supersede that delivery status or authorize starting duplicate services.

Production programme activation remains gated by current programme-data
permission, exact feed identity, real dated future programmes and both-node
snapshot verification. Source probes and candidate-review counts are not public
coverage. Two actual consecutive production versions and physical
Windows/macOS/Android hot-update, reconnect and uninterrupted-playback acceptance
remain incomplete.

### Current-gap future programme publication (2026-10-17)

An approved channel with a genuine gap at the current instant retains its
verified future rows in the immutable publication. No current title, end time or
gap-filling programme is generated. `channelsWithFutureProgrammes` and
`publishedChannelsWithFutureProgrammes` count this availability separately from
the stricter existing `currentAndFutureChannels` and
`publishedCurrentAndFutureChannels` metrics. Stale-only and current-only rows
without a future programme still cannot create a new publication.

The shared receiver and commit-time validation accept these future-only channel
windows, keeping current-programme queries empty and the upcoming timeline
available. This compatibility enhancement requires a new client build; it is
not retroactively added to already installed clients by a server update.
Real snapshot replay is performed in a temporary client database, independently
of Windows/macOS/Android physical uninterrupted-playback acceptance.

`website/tests/epg_contract_fixture.py` now emits two authored fixture versions
through the real ingestion and atomic publisher code in a temporary database,
with source reads and public-node reads simulated locally. The Dart
`test/server_epg_python_contract_test.dart` consumes those exact compressed bytes
through the normal receiver and background-isolate decoder. It checks two
versions, exact catalogue binding, route preservation, unchanged-version cache
avoidance, locked/private-source isolation and corruption/reconnect recovery.
The Python regression detects serializer drift. These offline fixtures create
no production permission, mapping, publication or real programme coverage, and
do not count toward the two-real-version acceptance gate.

The shared validator now stops automatic requests after HTTP 401/403 for every
source format, rather than limiting that boundary to CCTV. Existing denied rows
are reconciled to manual review once without an additional network request,
fabricated fetch time or loss of last-good metadata. Explicit review holds stay
paused. Rate limits, timeouts and 5xx failures retain their bounded retry/recovery
behaviour, and an unrelated source can continue. Authored tests cover all three
source formats and legacy-state reconciliation; no live access denial is injected.

A separate Frikanalen first-party documentation review found an explicit
EPG-aggregator redistribution use case and documented Europe/Oslo offsets. Its
first bounded XMLTV request returned HTTP 502. The candidate is now appended to
the existing persistent serial validator, with the real manual failure and its
original timestamp preserved in the primary database. Its first automatic check
cannot occur before 2026-10-16 23:05:02 UTC. A source-specific
`minimumRetrySeconds=3600` floor covers transient failures and interrupted
workers, without shortening a longer Retry-After or altering existing sources.
The first ordinary post-deployment timer run respected the deadline with no
upstream request. At registration, freshness, actual XMLTV timezone/bounds and
exact catalogue identity remained unverified. One catalogue name/full-ID
observation does not approve that precise feed or resolve its missing country
field. No grant, programme payload cache, mapping or publication was created.

The first ordinary automatic request began at 2026-10-16 23:05:03 UTC, after that
deadline, and recovered from the original 502. The validator accepted 456 actual
XMLTV records with current and future data for one source identity,
`frikanalen.tv`, at fetch time. Only diagnostic quality, identity and append-only
audit metadata were retained. Its next automatic check is not before
2026-10-17 00:05:03 UTC. Exact correspondence with the catalogue's `Frikanalen.no`,
independent calendar-timezone review and programme-data permission approval
remain pending. There are still no grants, approved mappings, programme payload
cache entries or published programme rows for this source. This diagnostic
recovery adds no public catalogue EPG coverage and required no manual source
request or service restart.

A follow-up read-only catalogue review observed one HTTPS route on
`frikanalen.no`, while the catalogue country/region fields and XMLTV identity
context remain empty. The in-memory matcher offers only a full-name proposal at
0.55 confidence; it is not a completed worker audit or an approved exact feed.
Homepage/API identity-page reads timed out through the web fetch tool, without
changing the healthy programme-source state or causing a feed retry. Authored
regression coverage confirms that a broadcaster-domain route and full name
cannot bypass the missing-country mapping guard. No raw URL credentials,
programme payloads or media were read or published during this provenance check.

### Preserved implementation milestones

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
active. This prevents clock-only full-catalogue rescan churn. Ingestion rejects
insufficient replacement windows and retains last-good rows. Publication can
retain their genuine future entries through a current gap, while live
current-and-future coverage stays lower; metadata candidates never establish a
live schedule.

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
Catalogue synchronization prepares identities before its write transaction,
reads the existing identity set once, and updates only changed, removed or
reactivated rows. An unchanged catalogue causes zero row changes, including its
checkpoint. Candidate states, leases and historical audits are retained for
unchanged identities. This reduces avoidable write contention without changing
the database journal mode or relaxing read-only API permissions; it does not
establish the cause of any earlier HTTP 503 response.

The read-only EPG manifest endpoint keeps its fail-closed HTTP 503 contract and
records only a finite diagnostic reason plus the primary SQLite result code.
Raw exceptions, paths, source URLs, programme bodies and credentials are never
logged by this diagnostic. Logging is thread-safe and capped at one entry per
reason per minute. A BUSY diagnostic remains evidence of contention, not proof
of which background task caused it.

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

At its outer boundary, the programme worker treats SQLite BUSY/LOCKED primary
and extended result codes as explicit `waiting_for_database` outcomes. It preserves the last
durable checkpoint, releases its worker lock, and leaves retry to the existing
60-second timer without an in-process loop. The deferred result omits unknown
coverage and publication values because an earlier batch may have committed.
Other database errors still fail visibly. Real exclusive-lock recovery and
checkpoint-preservation fixtures cover this transient-contention path.

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
UTC intervals, overlap and per-channel future availability are validated.
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
the new activation. A precomputed conservative future-availability deadline
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

### Historical bounded provider discovery

The country-provider entry point described below was replaced on 17 October
2026 by the channel-first identity gate documented under the pilot status.
Its code, jobs, retries and audits are retained; it is no longer the
`bobtv-epg-source-discovery.service` entry point.

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

A read-only follow-up at 2026-10-16T18:02:07Z verified two ordinary automatic
CCTV-2 probes. The latest health-success timestamp is 17:26:50 UTC, retaining 38 explicit-bound
records with one source identity having current and future programmes. This
inspection made no upstream request and created no programme, grant, exact
mapping or publication. The next ordinary request remains due no earlier than
18:26:50 UTC. The source calendar and programme-data permission gates remain.

Heartbeat counts now join the latest immutable catalogue's exact channel ID
and identity hash to the worker's read-only database snapshot. A normal catalogue
refresh can briefly differ from the worker's prior denominator; stale worker
identities never become current completed targets. At this follow-up both views
agreed on 8,746 targets, with 4,421 reviewed in the current source generation and
4,325 pending. A generation change is reported separately from append-only audit
growth, not presented as lost work or a negative completion delta. Public EPG
coverage and approved mappings remained zero. Shared client integration is now
available in the separately authorized 1.1.6 release; its first upgrade is still
required, and real EPG hot-update/reconnection/playback acceptance is pending.

### Licensed structured-identifier review policy

`licensed_structured_country_identifier_v1` adds review-only proposals when a
catalogue's full country-suffixed EPG identifier names an eligible TVmaze
network, even if its display name has a country annotation. For example,
`RTL.de@SD` and `RTL (Germany)` may propose the licensed DE `RTL` network for
review. The country must agree with both catalogue and source context. Only
full-name typography separators are normalized; numbers, words and plus signs
are never removed. The original identifier and variant are retained.

The additional path requires an existing currently valid data-use grant. It
does not infer that SD/HD, regional or delayed editions share a timetable.
Explicit plus/delay variants and US affiliate variants are excluded from this
new path. The low-confidence proposal has `contextVerified=false` and cannot
approve a mapping or store programmes. Existing exact-name rules, manual locks,
programme grants and the publication gate are unchanged. The matching-policy
version enters the source-review generation, causing one resumable recheck in
the existing five-channel batches without resetting any audit record.

The single-file server deployment followed 567 passing backend cases and a
five-channel trial on a private database copy. The trial kept the US affiliate
unmatched, added one RTL review proposal and preserved the other three existing
proposals. Production tables were unchanged during the file replacement; API
process IDs, classification files and timer configurations were preserved.
The ordinary timers were resumed with no manual upstream fetch or publication.
Read-only verification at 18:23:20 UTC confirmed 340 new-policy audit rows from
the normal timer and a byte-equivalent logical prefix of all 122,467 prior audit
rows. The RTL target is eligible for review when its ordinary queue turn arrives;
this verification does not claim that its production job has already run or that
its feed is approved. Public mappings and programme/publication rows remain zero.

The 18:57:34 UTC follow-up found the ordinary review generation complete for
all 8,744 current identities, with 137 review candidates and 8,607 unmatched.
The RTL production audit is now present and remains explicitly unapproved.
This completes one identity-candidate pass, not exact mapping, usable coverage
or the EPG feature. The prior append-only reviews remain separate evidence.

A bounded four-target feed-metadata review identified a concrete M6 risk.
The inspected `iptv-org/database/data/feeds.csv` lists French HD/SD feeds and a
Swiss feed under `M6.fr`, all using `Europe/Paris`; the Swiss feed is marked main.
An unspecified `M6.fr` must not be assigned a programme feed from the base ID,
catalogue country, network name, timezone or main-feed flag alone. ZDF SD,
RTL SD and True Crime SD/+1 metadata were also inspected without approving
their relay routes. Repository metadata/software licensing is recorded
separately and does not authorize programme-data reuse. No programme payload,
mapping approval or publication was added by this review.

At 19:12:31 UTC, current-identity completion remained 8,744/8,744. Two additional
changed-identity results were retained separately and did not increase current
completion. The French diagnostic's last-good window had expired and was
already queued for alternative-provider review; it was not counted as healthy
current/future coverage.

The following bounded HK-source investigation confirmed the public catalogue's
`RTHKTV31.hk` target. One official `/timetable/tv31` page request succeeded at
19:16 UTC under the pinned-public-network transport with a 1 MiB / 25 second
cap and no redirects. The 796,900-byte response was hashed, not retained as raw
programmes or converted. The optional language-query variant had failed local
URL-shape validation before network transport; the corrected query-free path
kept that guard intact. The inspected RTHK 2026-2028 open-data plan and annual
plan JSON description do not establish EPG-data permission. Calendar semantics,
freshness, exact feed mapping and programme-data use remain unverified. This is
an internal candidate review, not a newly enabled source or public coverage.

`epg_rthk.py` is a separate offline-only TV31 conversion prototype based on
the inspected upstream adapter and identity tests. It reads one exact channel
key from bounded JSON and inert HTML fragments, preserving explicit clock
bounds and any one-midnight rollover basis. It rejects missing/equal bounds,
conflicting identities/slots, overlaps, duplicate attributes, script-bearing
rows and deep/oversized inputs without filling timetable gaps. Requested-date
and timezone provenance remain marked as not independently live verified.
There is no fetch function, registry activation, database path or publication
approval in this module. Its 37 synthetic cases and all 604 backend cases passed;
the dated endpoint itself has not been fetched or validated by this prototype.
The earlier controlling English/Chinese copyright review at 11:36 UTC had
already excluded public-server ingestion until separate applicable permission
is established. Both later RTHK candidate records inherit that restriction;
their unverified flags do not mean that the terms have never been read.
Keep the offline synthetic prototype unregistered and undeployed. Separate
applicable permission must precede live adapter integration, followed by actual
response calendar/freshness and exact-feed validation. The software reference's
Unlicense does not establish programme-data rights. The ordinary terms review
cooldown remains 17 October 11:36:55 UTC, and the manual source-probe cooldown
remains 17 October 19:16:06 UTC. No new terms or programme-feed request was made
by this reconciliation. Nothing from this prototype was deployed.

## Licensed Taipei programme pilot, 17 October 2026

The zero-coverage investigation found that catalogue classification and EPG
candidate audits had not created programme-use grants, approved exact mappings,
an approved raw-payload handoff or published programme rows. The priority audit
contained 786 CN/HK/MO/TW catalogue identities, 107 with candidates, 83 with
exact ID/name candidates and zero with approved programme-data rights. These
candidate counts were not usable guide coverage. TVmaze-only provider discovery
also returned no usable CN/HK/TW result. Existing Chinese XMLTV permission and
RTHK redistribution restrictions remain separate unresolved gates.

`epg_taipei.py` now converts the official Taipei Broadcasting Station monthly
CSV into the two exact FM93.1 and AM1134 identities already present in the
public catalogue. The dataset is `https://data.gov.tw/dataset/121175`, with its
current resources at
`https://data.taipei/dataset/detail?id=536e992c-7087-451c-a0aa-f47aa98406ac`.
The checked `115年10月臺北廣播電臺中文節目表` is programme data released under
Open Government Data License 1.0, independent of source-code licensing.
Agency, year, exact monthly resource title, licence link and conversion notice
are retained in the public snapshot. This licence permits reuse with compliant
attribution without an additional written grant. No RTHK permission was inferred.

The adapter accepts only this fixed dataset and a strictly validated UUID
resource URL, uses pinned public DNS with no redirects, bounded serial reads,
and selects the explicitly published current month. The broadcaster frontend
supplies `Asia/Taipei` timezone evidence. Explicit month, weekday and start/stop
fields bound every expanded record; no following month, missing slot or programme
title is invented. Duplicate rows are deduplicated, all conflicting overlapping
records are excluded, and resulting timetable gaps remain gaps.

The 19 October 02:00 Tokyo inspection found an actual current-slot conflict in
the retained October CSV: two different titles claim 01:00 to 02:00 Taipei time
on weekdays in each of the two already locked radio identities. Both records
are excluded. At that check, matched identities and future-data identities
remain two while current-and-future coverage is zero. This does not establish
that either station is off air. The official dated web page separately shows
01:00 and 01:30 starts; its data rights and exact dated/channel binding require
review before it may override the licensed CSV. The CSV grant is not expanded.

`epg_coverage_gaps.py`, called by the existing bounded schedule timer, now
monitors up to five approved channels per run even when an unchanged cache has
an already completed ingestion receipt. It keeps per-channel durable jobs and
append-only transition evidence, including the identity hash, locked mapping,
source receipt, exact currently conflicting CSV rows, next accepted start and
next review time. Shared Taipei caches are checked and parsed once per batch,
without upstream fetches. Unchanged checks do not append duplicate audit rows;
recovery and revoked/drifted approvals are reflected without deleting history.
No programmes, mappings, grants or source retry floors are modified. This is a
coverage-review queue, not an implemented automatic replacement-search executor.
The full channel-bound replacement search and rights/mapping approval remain
unfinished. The client release and physical playback acceptance remain pending.
The ordinary server schedule process starting at 17:10:43 UTC on 18 October
loaded the deployed monitor and completed successfully. Both channel cases are
durably marked `current_source_slot_conflict`, with the original CSV row/hash
evidence and a 60-second review cadence. The EPG suite passes 851 authored and
contract tests. Code-only backups are retained under
`/opt/bobtv/backups/epg-coverage-gaps-20261019.hbve8z33`; no API or client process
was restarted. Physical platform playback acceptance is not implied by these
server tests.

The 19 October 02:18 Tokyo follow-up resolved the cached official FM page's
date/channel binding: its `programs-schedule1792339200000` data key is midnight
on 19 October in `Asia/Taipei`, and all 26 schedule records identify `fm`.
Explicit recording boundaries show 01:00 to 01:30 and 01:30 to 02:00. This
remains research evidence only; the website's separate programme-data permission
was not established. A targeted check of the independently licensed English
monthly dataset (`https://data.gov.tw/dataset/121271`) fetched its actual October
CSV and found the same two 01:00 to 02:00 overlapping entries. It is excluded as
a current-gap fallback, rather than treated as a successful alternate source.
The selected FM case, eight actual query strings, cache hashes, decisions and
08:22:48 Tokyo research retry were appended to the authoritative database's
coverage-gap audit and a private server receipt. Minute monitoring and the
02:56:14 source refresh floor remain unchanged.

A separate search-plan defect was corrected after 132 focused and 856 total EPG
tests passed: already reviewed programme-source phases had retained an instruction
to find a broadcaster identity profile. Each of the four ordered phases now asks
for its own actual programme format and data-use licence. Unknown identities
remain profile-only and cannot enter programme search. This one-module correction
was installed with a backup at
`/opt/bobtv/backups/epg-search-phase-goal-20261019.qsoectub`, without model changes,
new credentials, quota resets or process restarts. Ordinary process activation
and an actual reviewed-target programme-phase outcome are verified separately.
Protected mapping exclusion still applies to the original searcher; a dedicated
read-only alternate-source search consumer for approved-channel gaps is not yet
implemented, and no lock is weakened to hide that missing workflow.
The ordinary search process starting at 17:24:15 UTC loaded the corrected
module and completed with one accepted identity-search audit. No programme-phase
search occurred in that run, so actual programme-source discovery improvement
remains unproven. The protected existing credential and `gpt-6-sol` search model
were reused; classification remains configured for `gpt-6-luna` with upstream
limits. Separate follow-up is needed for the validator's handling of a Taipei
fetch made during a known conflicting current slot: its current generic
insufficient-current/future branch still marks that fetch failed despite valid
future rows. A specific partial-coverage change has not been implemented or
deployed as part of this search-instruction correction.

The ordinary server validator fetched the actual source at 23:49:46 UTC on
16 October. Two exact locked mappings and one attributed data grant were then
approved. The existing schedule timer imported 423 real programme records,
and the independent publisher automatically activated their two-node-verified
snapshot at 23:52:40 UTC. This is two currently covered catalogue identities out
of 8,744 at that check, with no claim of complete CN/HK/MO/TW or 24-hour coverage.
The six-hour source refresh, one-hour minimum error retry and existing bounded
workers remain enabled on the server without a Mac dependency.

The 17 October 09:08 Tokyo cadence update additionally caps a successful
Taipei source's next check at the next `Asia/Taipei` month boundary. A final
monthly file cannot keep the worker waiting six hours into the next month.
Intra-month refresh remains six hours, while failures and upstream Retry-After
retain their original backoff even across a month boundary. Year rollover and
leap-February authored tests, durable no-early-refetch behaviour and retained
last-good evidence after a cross-month 429 passed. No live month rollover is
claimed. The code-only deployment preserved all source receipts, grants,
mappings and the existing 14:49:46 Tokyo next refresh; no source fetch or API
restart was performed. Its backup is
`/opt/bobtv/backups/epg-taipei-month-boundary-20261017.Act6s5`.

The same ordinary publisher activated a second actual version at 00:00:51 UTC
on 17 October. Its 421 public records differ only by removal of two historical
records that aged out of the two-day retention window. Both nodes' new hashes,
contents and exact catalogue identities were independently verified. The same
shared receiver instance imported both real captures through the network-return
hook, retained cache offline and skipped unchanged downloads. This verifies
real automatic publication and shared-code version replacement, without claiming
that an upstream future-schedule extension or physical playback acceptance has
occurred. The raw last-good database still contains its original 423 records.

Deployment encountered a local/deployed catalogue-publisher mismatch. The
raw-inventory publication was replaced from the verified pre-change classified
snapshot, preserving all original channel IDs, routes and categories, with only
the two explicit country corrections. Root-created publication files were given
back to the service account after a read-permission failure. The deployed
Matcher and source-origin extensions were restored byte-for-byte, and the
metadata review hook was added narrowly to the deployed publication validator.
Do not deploy an older local inventory processor over those deployed extensions.
Evidence and recoverable pre-change SQLite/catalogue backups are under
`/opt/bobtv/backups/epg-taipei-pilot-20261017.ocuv6e`.

Real-snapshot import exposed an additional shared-client binding defect: the
managed mapping stored a raw catalogue channel ID while local programmes use
the source-prefixed EPG channel primary key. `ServerEpgBinding` now selects the
actual joined local EPG ID. Unchanged-version reconciliation also repairs an
older unlocked managed mapping without another download; private and locked
mappings remain untouched. Tests query current/next/next-next through the actual
mapping rather than substituting a hand-written programme key.

The shared receiver now accepts and displays the OGDL attribution accurately,
including its absence of a share-alike obligation. The already released 1.1.6
receiver does not accept this new licence metadata. This enhancement requires
a new client version; no release, device installation or app restart was made
for this pilot. Actual public snapshot import, unchanged-version deduplication,
offline retention and exact catalogue binding are checked with
`test/server_epg_live_contract_test.dart` using a fresh external capture in
`BOBTV_LIVE_EPG_CAPTURE`. Synthetic tests are not public source data. Windows,
macOS and Android physical hot-update/playback checks and automatic replacement
source acceptance remain outstanding. Keep the feature status incomplete.

### Channel-first identity gate, 17 October 2026

The existing enabled source-discovery timer now runs
`epg_channel_research_worker.py --focus-channel channel-e984a64118fb6e175592d18e`.
This is a bounded CCTV-2 pilot, not complete autonomous EPG discovery. The
worker uses the existing authoritative SQLite database and common worker lock.
It never fetches country-wide TVmaze schedules or calls the legacy provider
discovery runner. Already approved source refresh, ingestion, publishing,
grants, manual mappings and last-good programmes remain unchanged.

The durable queue records one actual catalogue target, its identity, category
path and route URL hashes. Removed targets are deactivated with history retained;
route, identity or category drift invalidates the research review. Non-revoked
mapping approvals remain protected even when temporarily invalid. Claims are
single-channel, leased and idempotent, and pre-commit a one-hour crash retry
floor. Incomplete identity is parked as `pending_identity`; a reviewed identity
without an implemented search executor is parked as `waiting_executor`.
Neither state invents a search, mapping, permission or programme record.

The later 17:00 Tokyo worker revision selects due cases read-only while the
network executor is unavailable. It reports `selectedDueChannels` separately
from `claimedChannels=0` and never advances an attempt counter or retry floor
for an idle observation. Existing leases, real retry floors, identity reviews
and recorded source/rights outcomes remain unchanged. The guarded claim API
continues to pre-commit its crash floor when an actual executor or explicit
reviewer uses it. This change does not enable autonomous network search.

The revision passed 119 focused tests and all 881 backend tests, then was
atomically deployed at 17:03:33 Tokyo without restarting APIs or changing timer
configuration. The ordinary 17:03:51 to 17:04:00 run used the new read-only path
for one due target, with zero claims, source requests or attempt increments.
The cutover preserved all twelve jobs, 54 prior research audits and all grants,
mappings and programmes. Recoverable code and fingerprints are retained under
`/opt/bobtv/backups/epg-research-noop-20261017.oYKdbG`.

A later catalogue-only observation records CCTV-2's category changing from
`中国/央视/财经` back to `中国/央视`, with all seventeen route hashes unchanged.
Its existing 18:45 review cooldown was retained through a hash-bound partial
identity observation. This did not approve the changed classification identity
or fetch programme data. The cause of the category reversion remains to be
investigated; all earlier identity and category evidence is retained.

The current CCTV-2 case has official canonical-name/number/financial-positioning
evidence, six historical EPG queries and five candidate outcomes retained on the
server as an append-only partial-case audit. Its public category is still
`中国/央视`; the financial subcategory is unapplied. Language, edition and delay
context across its 17 routes remain unverified. No candidate's data grant was
installed. Real multi-path network search execution and identity-review intake
remain unfinished; the fixed pilot must not be reported as global coverage.

Thirty-nine authored queue/worker tests and all 776 backend tests passed.
The first guarded cutover timed out during a ten-second systemd reload and
rolled back files, retaining the new research audit and restarting the timer.
Resuming the same queue with a thirty-second reload bound then succeeded;
the actual service exited zero and its timer is active and enabled. The next
identity-gate retry is 11:57:51 Tokyo. Main API and EPG API PIDs, source receipts,
grants, mappings and programme data were unchanged during the locked cutover.
Recoverable files and receipts are under
`/opt/bobtv/backups/epg-channel-first-20261017.GzWwP1`.
The subsequent automatic timer execution at 11:01:47 to 11:01:56 Tokyo also
exited zero with no network request or retry change. Before the successful
cutover, the old timer made two country-provider requests, one before the first
attempt and one in its rollback window. Those retained legacy requests supplied
no coverage and are not counted as targeted CCTV-2 searches.

At 11:00 Tokyo, both public nodes still expose the same 421-record snapshot for
two covered radio channels out of 8,767 catalogue identities, with zero covered
TV channels and no coverage increase from the queue deployment. The broader
feature, new client release and three-platform physical acceptance remain open.

### CCTV-2 category review, 17 October 2026 11:19 Tokyo

The selected CCTV-2 case now has the public category `中国/央视/财经` on both
nodes. All 17 inventory routes already carried that group, but the deployed
persistent Matcher's `catalog_channels` entity retained `中国/央视`. Ordinary
non-manual route matches preserve that cached entity group. The explicit
single-entity review updates only its group and category ID, with original-row
backup and an append-only review audit; route ownership, channel identity,
profile, EPG grants and mappings are unchanged. `review_catalog_channel_category.py`
is an administrative function, not an automatic classifier or EPG identity grant.
Its 16 authored guard/idempotency tests and all 792 backend tests passed.

Publication retained the deployed processor and used the existing atomic
catalogue validator/publisher. A normal inventory publication launcher exceeded
its bound; subsequent bounded publication of the exact current snapshot was
verified on both nodes, with every other channel and all target route hashes
preserved. Backups and receipts remain under
`/opt/bobtv/backups/cctv2-category-review-20261017.fJVbr2`.

This completes the financial category correction only. Full catalogue-feed
language/region/delay proof and programme-data use remain unresolved. The case
stays `pending_identity`, with its next queue retry no earlier than 12:18:13
Tokyo. A subsequent heartbeat can select another concrete priority target with
better original-feed evidence without discarding this audit or its cooldown.

The EPG publisher has four unique audited versions at this check. The latest
is `epg-8c0d45ba71a4eadf0a204a066568dddc04bf312b0b3cac8e4fa52f0e6668ab09`,
published at 11:06:23 Tokyo with 418 records. Compared with the prior captured
421-record version, it adds zero programmes and removes three historical rows;
the future coverage end remains unchanged. Actual two-version import and hot
replacement in one common receiver passed again. This is not an upstream
future-window extension, additional channel coverage or physical platform QA.

### Partial channel identity observations, 17 October 2026

The later channel-first pilot focuses on the actual catalogue entry
`channel-2c953e400a759b8f76bfe521`, 河南教育广播. The current public 云听
directory lists education station ID 1018 independently of tourism station ID
397. Its current stream path differs from the catalogue's original CNR route;
that old route returned a small master playlist without language or station
labels. This remains partial identity evidence, with no programme search,
mapping approval or data-use grant. The existing CCTV-2 and PBS Taichung cases
and all their evidence remain retained.

`record_identity_observation` appends a bounded, target-digest-bound review to
the same authoritative queue even after its scheduler has deferred the case.
It preserves attempt counts, longer retry floors and other channels, rejects
active leases, identity drift, inactive or already-reviewed targets, and does
not approve identity or report a programme search. Public source references
continue to reject private or signed-query URLs. Ten additional fixture cases
cover these guards; the queue/worker suite has 50 passing tests and the full
backend suite has 808 passing tests. This adds partial-review intake only.
The autonomous multi-path network search executor is still unimplemented.

### Staged protected search bridge, 17 October 2026

`epg_channel_search.py` is local, mock-tested preparation only. It is not
deployed or connected to the source-discovery timer. The current protected
proxy's live Responses/web-search support remains unverified. The bridge uses
the documented Responses `web_search` protocol, retains the configured model,
and requires a reviewed channel identity, a live lease, reviewed technical
domains and an explicit verified-proxy gate. It sends no private favourites or
stream URLs. Three serial tool calls, output/response limits and the existing
60/hour, 500/day shared worker budget remain enforced, including when unrelated
trusted classification jobs opt out of their own local limit.

The decoder requires real completed search-tool evidence and target-specific
queries when disclosed. Assistant prose claiming a search cannot substitute for
tool execution. Returned links are unverified candidates only; private, signed
or out-of-scope links are excluded without following them. No programme rows,
licences, approvals, publication or persistent queue success are created.
Authentication or explicit balance failures require operator action; temporary
rate limits preserve Retry-After and no model fallback is performed. Actual
proxy capability, durable worker integration and source validation are still
required before describing autonomous discovery as deployed.

### Reconnect catch-up and real clock boundary, 17 October 2026

Actual public captures span the Taipei AM1134 schedule gap and its 13:00 Tokyo
programme start. The normal publisher also activated an adjacent version with
414 rows instead of 416; the two removed records had already ended, retained
programme/provenance facts and the future coverage end were unchanged. This is
normal history pruning, not a new channel or a future-window extension.

The new capture replay exposed local connectivity backoff suppressing an
immediate reconnect check. The shared receiver now clears only SocketException
and TimeoutException retry state after a network-restored event, coalescing an
in-flight failed request into one catch-up. HTTP Retry-After and invalid-data
backoff remain intact. Thirty-eight receiver/capture tests pass, including the
real offline clock transition, actual adjacent-version import, unchanged-version
no-download and upstream Retry-After guards. This client code is unreleased;
installed clients were not operated and physical platform playback/reconnect
acceptance remains outstanding.

The full post-fix client suite passes 705 tests with 15 documented skips;
the scoped analyzer has no issues. The backend passes 849 tests, including 41
mocked protected-search cases. No application was installed, restarted or
released during this verification.

The staged search bridge follows the
[official web-search protocol](https://developers.openai.com/api/docs/guides/tools-web-search).
Its mocked protocol tests do not prove protected-proxy support or deployed
autonomous search. Two later bounded live capability requests returned HTTP
400 before verifiable search-tool execution; the safe diagnostic referenced
`max_tool_calls`. The accepted proxy parameter contract is still unverified.
The bridge remains undeployed, with no successful source search or coverage
attributed to those probes. Protocol failures now have a six-hour local retry
guard, which is also staged only.

### Known-case scheduling rotation, 17 October 2026 13:50 Tokyo

The enabled identity-gate service now uses `--preferred-channel` for the Henan
case. If that case is not due, one other already-enqueued, active and due case
may run. This mode never enqueues an unrelated catalogue target, shortens a
retry floor, bypasses the identity gate or enables network search. The existing
`--focus-channel` mode remains strict for explicit administrative runs.
`selectionMode`, `preferredChannelId` and `knownQueueOnly` distinguish these
modes in the durable checkpoint.

Five selected channel cases are retained. The new Inner Mongolia Music case
has a current public directory card ID 572, but its declared current stream
differs from the catalogue's legacy CNR HLS route. The original master declares
no track name or language. Full operator, frequency, language and feed-version
evidence remains incomplete, so it has no parser, programme search, mapping or
grant. The other four cases and their retry floors were preserved.

The guarded deployment and one-shot verification preserved all five job rows,
EPG grants, mappings, programmes, API PIDs and enabled timers. No case was
claimed because none was due; future due-case rotation is covered by fixtures
and still awaits a real due-case observation. Fifty-five queue/worker tests
and all 858 backend tests passed. Recoverable code, drop-in and job baselines
are under `/opt/bobtv/backups/epg-known-queue-rotation-20261017.tvcCpl`.
This deploys scheduling rotation only. Autonomous network search, source
validation/replacement and physical client acceptance remain incomplete.

### Family977 target and automatic publication, 17 October 2026 14:05 Tokyo

The public catalogue target `channel-471f1b9c367d9dd0c158035c` was selected
first. The current official FM97.7 player declares its exact catalogue URL,
`https://onair.family977.com.tw:8977/live.mp3`. The station profile confirms
Taichung and classical-music radio. One exact identity-and-route-bound TW
metadata correction was tested and deployed, preserving the other four
reviews, categories, routes, EPG approvals/programmes and API PIDs. Twelve
metadata tests and all 859 backend tests passed.

Six selected cases are now retained in the authoritative research database.
Family977 remains `pending_identity`: current comprehensive language and
delay-version evidence is incomplete. Preliminary target-bound source queries
are explicitly archived as unapproved reconnaissance, not completed
identity-gated discovery. Historical 2011/2013 NCC filings and unrelated
CLASSICA television listings were excluded. Weekly official slots do not yet
establish date validity, timezone and data-reuse permission. No parser, grant,
EPG mapping or programme row was added. Its retry floor is 20:10 Tokyo; the
other five case rows and floors were preserved.

The existing timers independently activated actual EPG publications 7 and 8.
Both public nodes verified the version-8 hash and contents. A real-capture
client replay imported version 7, survived offline operation and caught up to
version 8 in the same service instance; unchanged-version checks did not
download again. All 38 receiver/replay tests passed. The new version removed
two already-ended rows, added none and did not extend the future window.
Effective coverage remains 2 of 8,768 channels; this is not new coverage or
physical playback acceptance. The receiver is unreleased, and Windows,
macOS and Android physical verification remains outstanding. Autonomous
network search is still not connected to the server identity-gate worker.

### First identity-gated Radio 3 search, 17 October 2026 14:19 Tokyo

Catalogue channel `channel-0cb2510668eacd72e36302d9` (`RTHK3`) has one
operator-declared live URL. The current station HTML declares that exact URL
three times. The original page 18 of the operator's 2026-27 technical filing
was visually checked for Radio 3's English-language role and radio format.
An exact route-bound HK metadata correction preserves its existing name,
radio category and URL, plus the preceding five reviews.

Research identity was explicitly approved at 05:17:28 UTC before eight
channel-specific XMLTV, API/JSON, iCalendar, official-guide and open-data
searches. The official weekly and accessible dated timetable entry points
were located. No separately reusable programme licence was established;
the existing site-wide redistribution exclusion and terms-review floor were
retained. The attempted iptv-org channel XML reference returned 404, and a
third-party result exposed an old 2024 effective date despite a 2026 title.
No parser, source grant, EPG mapping or programme row was created.

The authoritative queue now retains seven cases: Radio 3 is `waiting_rights`
until at least 20:36:55 Tokyo, while the other six rows and floors remain
unchanged. Identity approval is limited to research and does not authorize
EPG publication. This search was performed in the current chat; autonomous
server network search remains unimplemented. Sixty-eight scoped metadata
and queue tests and all 860 backend tests passed, with one existing Starlette
deprecation warning. No API or client was restarted and no release was
created. The only new public change was the exact catalogue metadata review.

### Retain actual research outcomes, 17 October 2026 14:30 Tokyo

Four authored regressions exposed a future scheduler problem: an already
reviewed case with `waiting_rights`, `waiting_access`, `waiting_validation` or
`not_found` would lose that recorded outcome when its retry became due while
the network-search executor was unavailable. This had not happened to the
production Radio 3 case; its retry remains 20:36:55 Tokyo.

The queue now preserves the actual research result and identity evidence,
while recording executor unavailability separately. The worker checkpoint
adds `executionSafeError`, leaving `safeError` as the case outcome. Fresh
identity-approved cases without an actual search result still use
`waiting_executor`. No permission or programme validation gate is relaxed.

All 59 queue/worker tests and 864 backend tests passed, with one existing
Starlette deprecation warning. The two runtime modules were atomically
installed with recoverable originals under
`/opt/bobtv/backups/epg-research-outcomes-20261017.U1cdbG`. A controlled
one-shot succeeded without claiming any of the seven not-yet-due jobs. Their
rows, retry floors, research audits, grants, mappings and programmes were
unchanged; both API PIDs and all five enabled timers were preserved. Due-case
retention has fixture coverage; an actual future production due-case
observation is still pending. An ordinary timer run then started at 14:32:29
and finished successfully at 14:32:39 Tokyo, with zero claims or source
requests and the new execution-error field present.

No new channel search, source request, grant, mapping or programme row was
added in this heartbeat. Radio 3 remains identity-approved for research and
`waiting_rights`; the other six selected identities remain incomplete.
Current-and-future coverage remains 2 of 8,768 channels, and both public nodes
serve the same eighth EPG version and 412 programme rows. Autonomous server
network search and three-platform physical client acceptance are still
incomplete. The protected native-search protocol review floor remains
19:20:26 Tokyo. The shared EPG AI budget at the 14:30 check is 500 per day;
this does not apply to the completed original classification run.

### Guangdong Wenti selected-channel review, 17 October 2026 14:45 Tokyo

The next actual public target is `channel-b649d7568bad3b9da4ea955b`,
`广东文体广播`, with the existing `中国/广播` category and one legacy CNR
route. Twelve target-bound identity queries and three bounded metadata
checks were completed before any programme search. The current public
distributor profile identifies the full station name but does not bind the
original stream or establish its current frequency, language and regional
or delayed edition. The 263-byte original HLS master declares no `NAME` or
`LANGUAGE`. Its historical station host failed DNS resolution once; this
does not establish permanent station closure or a permanently dead source.

The case is retained as the eighth selected research task, `pending_identity`,
with a 20:45 Tokyo review floor. No programme endpoint, child playlist or
audio was requested, and no parser, identity approval, grant, mapping or
programme row was added. The first evidence write rejected the HTTP source
URL under the existing HTTPS-only audit contract after enqueue. The same
case was resumed without reset, using the successfully checked HTTPS
profile for the evidence-source field and preserving the original HTTP
route and manifest hashes inside the case. The strict guard was retained.

The preceding seven jobs, retry floors and audit records, plus all protected
grants, mappings and programmes, were verified unchanged. Recovery evidence
is under `/opt/bobtv/backups/guangdong-wenti-case-20261017.qfi5rn`.
All 59 queue/worker tests passed. No runtime module, API process, client or
release was changed in this heartbeat. Two catalogue-only name selections
found no Han Sheng/Fuhsing target; a partial ICRT match was a Mexican station
and was excluded without source research. Effective EPG coverage remains
2/8,768; selecting or investigating a case adds no usable coverage.
The ordinary timer completed at 14:46:07 Tokyo and acknowledged all eight
cases, with no claims or source requests. Repeating the archive command then
returned `already_archived` without another write or search/audit claim.

### Normal source refresh and Guangzhou General case, 17 October 2026 15:02 Tokyo

The licensed Taipei validator independently refreshed at 14:50:32 Tokyo.
Its cached source payload and CSV hashes were checked without an extra
upstream request. The 8,140-byte CSV retains the earlier verified hash.
Publication 9 activated at 14:52 with the same 412 programme facts and an
updated fetch timestamp/composite source-payload hash. Actual adjacent
publication receipts 8/9 include both-node proofs. The unchanged CSV is not
new coverage or a future-window extension.

Normal publication 10 activated at 15:00:32, removing two already-ended
rows and adding none. Both nodes verified the immutable hash and actual
contents: 2 channels and 410 public rows. Last-good database rows total 412.
The retained programme facts and provenance are unchanged from version 9;
the future coverage end is unchanged. Independent real-capture replays of
8 to 9 and 9 to 10 use the same common receiver instance per transition,
including offline/reconnect and unchanged-version download deduplication.
These are receiver tests, not Windows/macOS/Android physical playback tests.

The next actual selected target is `channel-df1048b91c002dcd9cfc52e5`,
`广州综合`, with one HTTPS gztv.com route. Twelve identity queries and two
bounded server checks preceded any programme-source search. Both server
reads timed out. The live browser reached the broadcaster site and its
TV/radio navigation/footer, but no named channel list loaded. Its player
had no declared/current media source and remained paused. No explicit
playback occurred; browser media network requests were not separately
measured. Third-party histories, stale timetables and editorial descriptions
were not adopted as identity proof.

The ninth selected case is retained as `pending_identity`, with a 16:10
Tokyo retry floor for this transient access failure. It has no parser,
programme query, grant, EPG mapping or programme row. The original eight
jobs, retries and audits plus all protected programme/grant/mapping data
were preserved. The existing `中国/广东` category remains unchanged; no
new subcategory or full channel-identity approval is claimed. Backup:
`/opt/bobtv/backups/guangzhou-general-case-20261017.qjY6rN`.
All 59 queue tests passed. No runtime module, API process, client installation
or release changed. Autonomous server network search is still unimplemented;
the next protected search-protocol review is no earlier than 19:20:26 Tokyo.
Both real transitions passed the same 38 receiver/sync tests separately,
not 76 distinct tests. The ordinary research timer acknowledged nine cases
at 15:02:02 Tokyo with no claims or source requests. Repeating the archive
returned `already_archived` without another write. The shared EPG budget
briefly admitted at 15:01 (498 daily calls), then reached 500 again at 15:03;
the next possible admission without other calls is 15:15:48 Tokyo. This
heartbeat made no AI request, and the original completed classification is
unaffected.

### Putonghua identity and targeted search, 17 October 2026 15:19 Tokyo

The next selected public channel is `channel-f9575f6ac5f72cf9df249366`,
`RTHK普通话`. Current operator HTML names 香港電台普通話台, identifies
AM621 and declares the exact original live URL three times. The previously
cached 2026/27 operator technical filing was hash-checked and its original
page 18 visually reviewed for the principal Mandarin, nonexclusive language
role and general radio format. No PDF, child playlist or audio was fetched.
An exact route-bound HK metadata review preserves the existing channel name,
radio category and route. Both public nodes retained all seven reviews in
the later normal catalogue refresh at 06:17:52 UTC, after the bounded manual
publication at 06:14:17 UTC. No API was restarted.

Identity was explicitly approved for research at 06:14:30 UTC. Eight actual
target-specific XMLTV, API/JSON, iCalendar, official-guide, repository and
open-data searches followed. Official timetable form and season/block
notices were found; no separately applicable schedule redistribution
permission, current/future schedule validity or source timezone semantics
was established. Existing site-wide terms evidence and its review floor
were reused. An indexed weekly PDF and CIBS season notice remain leads;
neither was fetched or parsed. No programme facts were extrapolated.

The initial evidence write safely rejected an expired two-minute claim.
Search completion had already been observed by 06:15:19 UTC, within the
original lease. A tested bounded observation helper now archives that
completed work only if the original identity, token and expired lease still
match the untouched search-pending job. Replaced claims, changed feeds,
inactive/protected jobs, missing identity, out-of-lease completion and
repeated writes are rejected. No lease is renewed, search repeated, attempt
counter reset or retry floor shortened. Thirteen new regressions bring the
queue/worker suite to 72 and the full backend suite to 878, with one existing
Starlette warning. The previous runtime module is recoverable under
`/opt/bobtv/backups/rthk-pth-review-20261017.WJLinH`.

The actual search was archived at 15:19:13 Tokyo as `waiting_rights`, with a
21:25 review floor. All nine preceding jobs and protected programme,
mapping and grant fingerprints were unchanged. Ten cases are retained:
eight pending identity and two waiting rights. Five server timers remain
active/enabled, independently of this Mac. The automatic network-search
executor remains unimplemented; the native-search protocol review floor
is still 19:20:26 Tokyo. This heartbeat made zero AI requests. At 15:19:21,
the shared EPG rolling daily count was 497 and admission was available;
the original completed classification has no local daily cap.

Effective current-and-future coverage remains 2/8,768, with 146 retained
candidate proposals and seven failed sources. Both nodes still verify EPG
publication 10, its identical hash and actual 410 public programme rows.
Last source success remains 14:50:32, next 20:50:32 Tokyo. No new mapping,
grant, programme row, future-window extension or usable channel coverage
was added. Client enhancements remain unreleased, and Windows/macOS/Android
physical hot-update, reconnect and uninterrupted-playback acceptance plus
general alternative-source discovery remain incomplete.

The next ordinary research timer completed at 15:20:05 Tokyo with the new
queue module, acknowledging ten retained cases and making zero claims or
source requests. Replaying the retired Putonghua claim was rejected with
zero database writes, one retained completed-search audit, and unchanged
attempt count and retry floor.

### Bravo FM91.3 partial identity, 17 October 2026 15:30 Tokyo

The next actual public target is `channel-51305916c1e5f7beb6aa6b6d`,
`BravoFM台北都会音乐台`, with its existing `中国/广播` category and one
original `https://onair.bravo913.com.tw:9130/live.mp3` route. Eleven
target-bound identity queries were followed by two bounded first-party
HTML checks. The 72,221-byte root declares the exact original URL three
times; the 46,898-byte linked about page declares it once and identifies
Bravo FM91.3 and 財團法人台北勞工教育電台. The full foundation name is an
indexed regulator-directory lead, not a separately fetched/current approval.

Current broadcast language and exact regional/fixed-delay context remain
unverified. NCC search results with recent engine publication labels contain
actual 2011/2012 dates and cannot establish present-day language or schedule
validity. Incidental programme snippets were not adopted as programme-source
research, future schedules, source-timezone evidence or reuse permission.
The current about HTML also contains unrelated gambling-link markers. No
external link was visited, no page script or audio was executed, and no site
compromise diagnosis is asserted. Neither the old stream playability date
nor a website-language label is sufficient broadcast-language evidence.

The case was archived at 15:30:23 Tokyo as the eleventh retained task,
`pending_identity`, with a 21:40 review floor. All ten preceding rows,
retry floors and earlier audits plus protected programme/grant/mapping
fingerprints were verified unchanged. No identity approval, public metadata
review, EPG mapping, grant, parser or programme row was created. The existing
queue/worker suite passed all 72 tests. No runtime module, API process,
client installation or release changed. Backup and case evidence:
`/opt/bobtv/backups/bravo913-case-20261017.QfWWDL`.

Coverage remains 2/8,768 with current and future programmes, 146 retained
candidate proposals, seven failed sources and 410 public programme rows.
Both public nodes first verified the actual version-10 snapshot contents;
a subsequent no-cache manifest-only check confirmed the same version/hash
without a second snapshot download or programme parse. The five independent
server timers remain active/enabled. Network-search execution is still not
connected to the channel-first worker, and the protected capability-review
floor remains 19:20:26 Tokyo. The shared EPG AI budget at 15:30:45 is 500
daily requests, with earliest admission at 15:56:45 absent other calls;
this heartbeat made no AI request. The completed original classification
is unaffected. Client enhancement release and three-platform physical
acceptance, future-window extension and general alternate-source discovery
remain outstanding.

The ordinary research timer acknowledged all eleven cases at 15:31:23 Tokyo
with zero claims or source requests. Repeating the archive returned
`already_archived` without another production write.

### PBS Taipei selected identity review, 17 October 2026 15:43 Tokyo

The next public target is `channel-f36895d08509b46ba6fbded6`,
`警察广播台北分台`, with one original HTTP1935 `TPS` route and its existing
`中国/广播` category. Ten target-specific identity queries preceded any
programme-source research. Two bounded current primary HTML checks confirm
the broadcaster name 內政部警政署警察廣播電臺 and identify 臺北分臺 as
regional FM94.3. The national network and other regional FM94.3 stations
remain separate identities.

The previously checked 2,231-byte official player script maps `TPS` to
警廣臺北臺 and supplies an HTTPS443 stream formula. Its 11:41:28 Tokyo
receipt and hash were reused without another script download or execution;
this does not claim that the script was revalidated as unchanged now. The
actual old HTTP1935 URL and formula-derived HTTPS443 URL each returned a
small HLS master, 106 and 105 bytes respectively, without language tags.
The hashes differ. This neither proves exact body/edition/delay equivalence
nor establishes that they are different stations. No child playlist or
audio segment was fetched.

Current channel-wide broadcast language and the exact legacy feed edition
remain unverified. The case stays `pending_identity`, with a 22:00 Tokyo
review floor. No full identity approval, EPG-source search, parser, grant,
mapping, programme row or public metadata correction is claimed. Incidental
programme/news snippets from identity searches were not adopted as future
schedules, broadcast-language proof or data permissions. All eleven earlier
jobs, two waiting-rights outcomes, retries and historical audit rows plus
protected EPG data were verified unchanged during the bounded archive.

All 72 queue/worker tests passed. No runtime module, API process, client or
release was changed. The independent timers, actual two-channel coverage,
snapshot version and shared-budget admission are checked again for the
heartbeat receipt. Automatic server network search remains unimplemented;
its protected capability review is not due before 19:20:26 Tokyo. Client
enhancements remain unreleased, and three-platform physical acceptance,
future-window extension and general replacement-source discovery remain
incomplete.

The case was archived at 15:44:59 Tokyo. The normal research timer then
acknowledged twelve retained tasks at 15:45:07 with zero claims or source
requests. Repeating the archive returned `already_archived` without another
write. The source remains healthy at its existing 14:50:32 success and
20:50:32 next refresh. EPG manifests on both nodes still reference the same
content-verified tenth version/hash and 410 programme rows; no snapshot or
programme parsing was repeated for the unchanged version. Coverage is still
2/8,768, with 146 retained proposals and seven failed sources.

### Guangdong identity-search canary, 2026-10-17 21:29 Tokyo

`bobtv-epg-identity-search.timer` and its bounded oneshot service are now
deployed independently of the Mac. They enable identity-only web search for
one reviewed catalogue feed, `channel-b649d7568bad3b9da4ea955b`, 广东文体广播.
The current name, EPG identifier, CN country, 中国/广播 category and original
CNR route hash must all match the durable job. Changed identities, protected
mappings and approved programme identities are excluded. The older thirteen-case
research timer remains a read-only due selector; this canary does not enable
general programme-source search or reverse provider matching.

The exact streaming request body matches the successful isolated native search
at 21:04 Tokyo. This deployment made no new API request: the real review floor
remains 2026-10-18 11:00 Tokyo. The first actual due execution is still pending.
The canary returns unverified technical-profile URLs only. It does not retain
model answers/editorial titles, follow candidate pages, approve station identity,
grant programme-data rights, create mappings/programmes or publish snapshots.
The station's current frequency, complete languages and original feed edition
remain unresolved. Historical PDFs, dated distributor archives and programme
pages are excluded by the candidate-path gate.

Admission uses the existing atomic 60/hour and 500/day EPG budget. A budget
deferral does not claim a job or advance its real review floor. A claimed crash
retains a one-hour floor, and repeated incomplete identity searches have bounded
exponential backoff. Authentication or explicit quota/balance failures persist a
manual suspension in the authoritative EPG database, including when an audit
commits before the latest-checkpoint write. No key is printed or created, no
model fallback is used, and the completed Luna classification is unaffected.
The existing reviewed domain policy itself expires for review on October 24;
licensed source-refresh and publication timers remain independent.

Local validation passed 178 focused tests and 940 backend tests. The production
venv has no pytest; no test dependency was installed there. Its actual runtime
passed a RAM-only replay of all thirteen jobs and the current catalogue, with
credential, admission and transport callbacks forbidden while idle. It also
accepted a clearly labelled normalized metadata replay of the previous real
native search, retaining three technical candidates from thirteen unverified
links. This was not a new search or a replay of the original raw API response.
Installation verified zero changes to research jobs/audits, mappings, data grants
and programmes. The original five business timers, API process and queue modules
were preserved. The install receipt is under
`/opt/bobtv/backups/epg-identity-canary-20261017.CRMQf7`.

The ordinary timer subsequently triggered at 21:31:09 and the service exited
zero at 21:31:18. It again retained the real 11:00 review floor and zero attempts,
native requests, new audits or identity approvals. This verifies independent
periodic idle execution; the first actual due native request remains pending.

`epg_channel_search.py` is installed only as a dependency for shared admission
and safe deferral helpers. Its older programme-search request builder remains
unwired and has not passed a live compatibility test. General autonomous
discovery, automatic candidate fact/rights validation, alternative-source
acceptance, client publication and three-platform physical playback validation
remain incomplete.

### Server-only inspection, 2026-10-18 08:47 Tokyo

The completed classification still has 6,939 reviewed current identities and
zero pending, plus 110 retained historical records. Its 7,049 unique audit
records are consistent. Both public nodes still serve the original completed
classification snapshot. The configured model remains `gpt-6-luna` with
upstream-limit backoff. The completed unit is inactive with a successful result;
it was not restarted.

Fresh public checks found 8,741 catalogue channels and 9,603 unique route URLs.
A hash-validated comparison with the 00:43 snapshot found 23 old channel IDs
absent and 11 newly present. All 9,602 old route URLs are retained under current
channel IDs, with one additional route URL. This comparison does not independently
approve the identity correctness of every renamed or merged record.

Verified EPG coverage remains two matched channels with current and future
programmes, 2/8,741 or approximately 0.0229 percent, with zero coverage gain.
There are 125 retained candidate reviews excluding valid approvals and six
failed source records. Automatic publication advanced from 19 to 27 publications
since the previous completed inspection. Both nodes serve
`epg-0df721b98ac61a5e53cd88e79c40c261513ff1b49908ec765cab1bcb72399eda`,
generated at 08:00:40 Tokyo with 429 programmes. Public compressed-byte hashes,
programme identity, current plus subsequent programmes and dynamic/immutable
cache policies were checked on the main site and relay. All six EPG timers
remain enabled and active independently of this Mac.

The due selected identity was 河南教育广播,
`channel-2c953e400a759b8f76bfe521`. The public category 中国/广播, inventory
category 中国/广播/河南, one original CNR route hash and both zero manual flags
were rechecked before six channel-specific identity searches. Two primary
technical directory shells were readable; a third-party technical diff lookup
returned 403 and was not bypassed. Original-feed association, whole-feed language
and regional or delayed edition remain unconfirmed. Programme-source search,
parsing, mapping and grants did not begin. Two audit rows were appended in the
authoritative database with next review at 2026-10-19 09:00 Tokyo. An idempotent
replay added nothing. The other thirteen jobs and retries, prior audits,
programmes, grants, manual metadata and mappings were retained. The guarded
backup is `/opt/bobtv/backups/henan-identity-review-20261018.5201ltae`.

The deployed channel-first known-queue selector remains active. Its broad
autonomous network-search executor is still unimplemented. This inspection's
research was performed by the current chat, not by that executor. The 75 focused
queue and worker tests pass. No runtime code, API process or business timer was
restarted. Desktop publication remains explicitly paused after the Windows host
shutdown. Radio artwork and playback-state wave rendering, native disposal and
video handoff fixes remain unshipped; installed applications were untouched.

### Channel-first automatic search executor, 2026-10-18

`epg_auto_search_worker.py` replaces the read-only selection entry point in
`bobtv-epg-source-discovery.service`. Deploy both the unit and
`deploy/bobtv-epg-source-discovery.service.d/20-channel-first.conf`; an existing
ExecStart override otherwise keeps running the old selector even when the unit
file was replaced. Verify the effective systemd command, not only its file hash.
The worker is serial, capped at three channels per run, a 150-second admission
window and a 180-second systemd timeout, with the existing 384MiB/15-percent-CPU
limits. The persistent timer continues independently of the Mac. The separate
fixed Guangdong canary timer is disabled to prevent duplicate search lanes;
its source, previous observations and real retry floor are retained.

Each task starts from one actual current catalogue identity and its route hashes.
Existing due tasks rotate first. When none is due, one previously unselected
public target is admitted, prioritizing explicit CN/HK/MO/TW metadata and public
playability evidence. No private favourites, country-wide schedule scan or
provider-first reverse matching is added. Unknown identities get identity-only
queries. Previously explicitly reviewed identities use XMLTV, structured API,
official-schedule and factual-arrangement phases in order. Full names, aliases,
numbers and reviewed feed editions stay in channel-specific queries.

Every completed task saves its requested and actual query, search-tool execution
evidence, candidate/exclusion reasons, bounded technical access checks, catalogue
identity, unresolved fields and retry time in the authoritative research audit.
Identity uncertainty, empty results, invalid responses and transport failures
park that channel and allow the next one. Backoff grows from six hours to seven
days, preserving longer existing floors. A crashed claim retains a one-hour
floor. Shared EPG budget and upstream rate-limit waits are durable and do not
consume channel attempts before admission. Authentication or explicit balance
failure suspends the lane for manual action. Classification's Luna/upstream-only
policy is unchanged. The existing protected HTTPS endpoint and EPG model are
reused with no new key and no model fallback.

Candidate access is HTTPS/public-DNS pinned, query/credential free, without
redirect following, cookies, authentication or signature replay. Identity pages
are limited to technical paths, 256KiB and bounded reads. Source schedules get
HEAD-only access pending separate content/rights validation. Six-hour shared
URL-check caching prevents repeat downloads and never reuses a different
channel's name excerpts as identity evidence. HTTP200, search hits and model
answers never establish current/future coverage or publication permission.
This executor does not automatically approve identity, grant data rights, change
player mappings, parse unreviewed schedules or publish programme data.

The 46 new executor checks and all 763 EPG regression checks passed. Full backend
regression also reproduced two unrelated existing failures:
a homepage assertion still expects version1.1.6 and a request-isolation assertion
still expects network-profile503 instead of its current200 response. Neither
website copy nor those unrelated tests were changed for this deployment.
Production's current fourteen jobs additionally passed a clearly labelled RAM-only
three-target synthetic replay before installation. That replay made no real AI
or source request and did not change the authoritative queue.

Installation preserves all previous jobs, audits, programme rows, grants and
manual mappings, with recoverable files under
`/opt/bobtv/backups/epg-auto-search-20261018.05npp0ph`. The first ordinary new timer
trigger at 09:03:11 Tokyo completed three serial real identity searches for
警察广播台北分台, RTHK TV 31 and CCTV-2, and two bounded primary technical-page
checks for the RTHK target. Each actual tool query matched its selected channel.
Unresolved identities retained their gates and advanced their own retry floors,
without programme search or mapping changes. Subsequent native task/timer acceptance is recorded
in this task's `automatic-search-20261018-*.json` receipts. Main and EPG API
processes were preserved. Desktop publication remains explicitly paused;
installed applications were not restarted.

The next ordinary timer triggered at 09:06:31 and completed actual searches for
警察广播台中分台 and 广州综合, with two additional bounded technical-page checks.
It skipped all three previous targets' cooldowns, then reached the shared EPG
daily-budget admission gate before claiming 台中广播电台. The persisted safe
error was `search_budget_deferred`, with the next eligible slot at 09:08:50 Tokyo.
No attempt or real review floor was consumed for that deferred target. Thus two
independent native runs completed five different channel searches, with no
identity approvals, grants, mapping writes or new programme coverage. The final
server acceptance receipt is `automatic-search-acceptance.json` in the guarded
backup directory above. Both public nodes still have two verified channels with
current and future programmes, now 2/8,740, and matching immutable snapshot hashes.

### Search execution health, 2026-10-18 14:32 Tokyo

The 14:25:31 automatic search batch retained two completed channel audits, then
logged `auto_search_worker_check_failed` at 14:26:22. Its final channel claim
outlived that process. The existing two-minute lease and one-hour retry floor
remained intact, and the ordinary timer started a later batch. The old generic
log does not establish the underlying exception type.

The worker now records each completed or deferred execution separately in
`channel_auto_search_last_execution`. Infrastructure failures store only an
allowlisted error family, a safe SQLite code when available, and an internal
phase label. Raw exception text, requests and credentials are excluded.
Uncommitted statements are rolled back before this independent health receipt;
already committed audits, manual mappings, grants and retry floors remain intact.
Read-only inspection also checks the actual systemd process and start time
before reporting a retained lease as an in-flight search.

The 107 focused rotation, retry-floor and execution checks and all 769 EPG
regression checks passed. The staged server worker passed an in-memory failure
and recovery check without AI requests or production database writes. Only the
worker file was atomically replaced; no unit or timer command was run, and main
and EPG API PIDs were unchanged. Recoverable files and the deployment receipt are
under `/opt/bobtv/backups/epg-search-execution-health-20261018.h1uvfqzi`.
The initial receipt left ordinary timer execution verification pending. The
ordinary timer started the updated worker at 14:33:28 Tokyo and persisted a
`waiting_shared_admission` execution receipt at 14:33:46, without claiming a
channel or making an AI request. The new runtime hash and unchanged API PIDs
were independently verified at 14:34:02. This observability change does not
claim to fix the unknown previous
exception, approve identities, increase EPG coverage, or complete client tests.
Desktop publication remains paused and no installed application was restarted.

### Search-reference target context, 2026-10-18 16:33 Tokyo

The completed search count now distinguishes attempts from accepted query
execution evidence. Between the 16:13 report and this inspection, five attempts
finished: four returned verifiable query evidence, while Hebei Life Radio's
response was rejected and parked. None established a complete channel identity
or added a mapping, grant or programme. Several older accepted search responses
referenced other stations' technical pages; those results are retained as
historical evidence, without adoption.

The tested search module now excludes references without a full target label,
recorded alias or EPG label in the reference title/path before any HTTP check.
An explicitly configured primary homepage remains an operator-research entry
point. Numeric prefixes and plus variants remain distinct. Untrusted reference
titles only guide bounded retrieval and are never stored as identity facts.
Excluded references retain a URL hash and safe reason. Existing caches, audits,
identity gates, rights gates and source-refresh schedules remain unchanged.

All 68 focused search checks, 799 EPG/catalogue regression checks and ten local
heartbeat-accounting checks passed. The only warning was a framework deprecation.
The server's staged in-memory guard check passed without an upstream request.
Only `epg_auto_search.py` was atomically replaced at 16:33:46. Backup and receipt:
`/opt/bobtv/backups/epg-search-target-context-20261018.ca3t1g_8`.
The ordinary timer started a fresh worker at 16:33:48 and completed its quota
wait at 16:34:01. Runtime hash and unchanged API PIDs were verified independently.
Real searches using `candidateReferencePolicy=selected_target_context_v1` remain
pending because shared admission next opens for checking at 16:57:33. This is
not evidence of increased coverage or completed client hot-update acceptance.
The existing protected HTTPS configuration was reused under the user's prior
authorization; no credential was created, printed or changed. Desktop release
publication remains paused and no installed client was started or restarted.

### Regional category scheduling, 2026-10-19 05:58 Tokyo

The selected public 公視 target has an empty country field and category
`国际/台湾`. Its original deployed research score was 10, placing it in the
nonpriority bucket. The automatic worker now uses exact public regional
category labels only when country metadata is empty. Explicit country metadata
keeps precedence. The hint never fills country, confirms an identity, changes
a mapping or searches a programme source. Existing jobs keep their stored
within-bucket playability score, identity review precedence, leases and retry
floors; new admissions remain one concrete catalogue target at a time.

The single worker module was installed at 05:55:46 Tokyo after all 1,044 EPG
regression checks passed. The ordinary timer started it at 05:57:33 and finished
successfully at 05:57:48, independently of the Mac. Protected mapping/grant
digests, PTS job/audit, dependencies and API process IDs were retained; the
installer made no production database writes or upstream/AI requests and
restarted no service or timer. Recoverable files and receipt are in
`/opt/bobtv/backups/epg-regional-research-priority-20261019.goumshle`.
This confirms scheduler activation, without new PTS searches or EPG coverage.
Public category hints do not resolve the selected PTS feed's missing language,
operator-to-route, geography or edition evidence. Its 11:31:43 Tokyo review
floor remains in force. Client/catalogue repair publication remains paused.

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
