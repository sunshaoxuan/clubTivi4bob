# BobTV website and API

This directory is the canonical source for `https://bobtv.briconbric.com`: the public site, the local release mirror, the video-source APIs, and bounded diagnostic intake. The Flutter application lives in `lib/` in this same repository. Existing GitHub release assets are mirrored to the server; users download from the BobTV host. Deploy `route_identity.py` alongside the inventory and catalog publisher. [Route identity](ROUTE_IDENTITY.md) describes global deduplication and permanent retirement across rediscovery and URL spelling variants.

The product page describes BobTV as a Windows and macOS desktop TV player. Windows 10 compatibility requires client-side validation before publishing a support claim.

The hero image is a user-provided crop of the BobTV simplified-mode interface with playback and channel listings visible. Product, downloads, and diagnostic uploads are separate pages. Source reporting is API-only.

The product, download and diagnostic pages share a dark navy and peach visual system and the supplied real player screenshot. Build `1.0.1+82` adds mouse-reveal Windows fullscreen window controls and dedicated desktop Exit buttons. It retains a Windows Setup installer with optional desktop shortcut, unified fullscreen return behavior, and Unicode DLL path support. Windows managed installations require administrator-authorized Setup upgrades; portable Windows and writable macOS installations retain automatic updates. It retains durable shared synchronization and adds on-demand source management, canonical route deduplication and monotonic retirement across equivalent URLs. The download page explains initialization and both platform update flows; the diagnostic page describes optional, default-off summary uploads. Descriptions do not claim Windows 10 validation or guaranteed third-party stream availability.

## Website languages and copy (2026-10-05)

Product, downloads and diagnostics use server-rendered Jinja templates in
`templates/` and four complete copy dictionaries in `locales/`: `zh-CN`, `en`,
`ja` and `zh-TW`. Copy describes verified behavior and installation limits
directly. Keep all dictionary keys, message placeholders and product facts in sync
when publishing a release. Dynamic download and upload messages are localized too.

Language priority: valid `?lang=` choice, then the `bobtv_language` cookie,
then trusted Cloudflare `CF-IPCountry`. CN selects Simplified Chinese; JP Japanese;
TW/HK/MO Traditional Chinese. Every other country, missing/invalid country and
untrusted peer selects English. Language choice is remembered for one year;
the cookie is HttpOnly, SameSite=Lax, and Secure on HTTPS.

The navigation language control is plain text at the same font size as adjacent
links. Its arrow appears on hover or keyboard focus. Selection submits immediately
without a separate confirmation button. Mobile retains the native choice picker.
No IP lookup service
is called and this selector does not persist visitor IPs. HTML responses are
`private, no-store` with Content-Language and Vary headers. All internal page links
carry the selected locale; installation byte routes remain unchanged.

Geolocation trust requires nginx to overwrite X-Forwarded-For with its remote
peer, uvicorn to trust only the loopback nginx proxy, and that peer to be in
`cloudflare_ranges.json`. Do not enable nginx real_ip rewriting without revisiting
this contract. A direct-origin request cannot select a language by forging country
headers. Local processes are within the existing trusted reverse-proxy boundary.

Deploy `localization.py`, `templates/`, `locales/`, `cloudflare_ranges.json` and
the changed assets/app, and install `requirements.txt` before restarting. The old
root-level HTML files are removed. Back up the affected runtime files first.
Acceptance covers all 12 page/language combinations, GET/HEAD, country mapping,
spoofing rejection, cookie priority, dynamic success/error states, desktop/mobile
layout, console/network errors and unchanged local download bytes.

## Installed-device footer count (2026-10-06)

The footer counts distinct registered hardware-host hashes in a separate
`device_registry.sqlite3`, with an integer in parentheses in every language.
`HostFingerprintService` reads Windows SMBIOS UUID via WMI or macOS
IOPlatformUUID, trims and lowercases its canonical UUID string, then SHA-256 hashes
`BobTV-host-v1|uuid` with prefix `bth1_`. No installation salt, platform salt, preferences,
OS user ID or OS-specific MachineGuid participates. Repeat installs using the
same firmware identity register the same key. Empty, malformed, zero, all-FF and
the known default UUID `03000200-0400-0500-0006-000700080009` are unobserved.
There is no random hardware fallback. Existing salted channel-sync identity
and channel databases are unchanged. Raw hardware values are never uploaded.
Hashes are pseudonymous persistent identifiers, not guaranteed anonymous data.

Startup registration runs independently of UI startup, with at most three
attempts and 8-second hardware-process timeout. Public aggregate-only count reads
are no-store; the footer refreshes every 30 seconds and on visibility/online
return, with an 8-second request deadline and one request at a time. Failure
removes the numeric suffix; a healthy empty registry displays `(0)`.

Before enabling the API, run as bobtv:
`BOBTV_DATA_DIR=/var/lib/bobtv /opt/bobtv/venv/bin/python /opt/bobtv/site/device_registry.py`.
The explicit version-1 migration is transactional and idempotent, creates its
own database and never backfills the 45 historical salted installation IDs.
They cannot establish the number of distinct hosts. Deploy the new module,
app/localization/template and `assets/device-count.js` together, then restart.
Rollback restores those runtime files; old code ignores the new database.

Coverage starts with clients containing this new registration code. Website
deployment alone does not update existing desktop packages. Offline/old clients
remain unobserved. The metric is cumulative observed firmware identities, with
no uninstall detection or installation attestation. Duplicate vendor UUIDs and
cloned VMs can merge hosts; changed motherboards or VM UUIDs can create new ones.
SHA-256 collisions are a separate, negligible risk; hardware-source uniqueness
cannot be guaranteed. Public registration is rate/capacity bounded, yet spoofable.
Do not use this count for billing, authorization or an exact hardware census.

## Release content review

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

## Release mirror

The download page selects the latest verified installer independently for each platform and labels its exact version. A platform-specific release does not remove another platform's previous installer or advance its update feed. Release 1.0.2 currently provides macOS packages; Windows remains at 1.0.1 pending its powered-off build host. Client checks now display a checking spinner, an explicit result, and an authorization-required state for protected Windows Setup installations. Foreground checks are throttled to 15 minutes in addition to startup and six-hour checks.

Current releases mirror Windows x64 ZIP packages and both macOS architectures' DMG installers and signed update ZIP archives. A single download row presents the three manual installers; automatic updates use separate platform feeds.

Run `python mirror_releases.py` in this directory with `BOBTV_DATA_DIR=/var/lib/bobtv`. It reads public GitHub release metadata and downloads each matching BobTV Windows x64 ZIP or Setup EXE and macOS DMG into private staging. Size, ZIP signature, and GitHub's SHA-256 digest where present are verified before manual-download manifest publication. A release can additionally contain `BobTV-update-metadata.json` with `schema`, numeric `version` and `packages` entries containing `platform`, `filename`, `sha256` and `bytes`. Mac packages also require a base64 P-256 `signature` over the exact ZIP bytes. The mirror checks that signature with the bundled public key before publication. Each listed package is downloaded and verified before its platform's `latest.json` is atomically replaced. Older releases without this metadata stay manual downloads. Mac packages must be physically tested on their target architecture; CI test artifacts remain outside the release feed. Downloads are served from the local filesystem. The server needs outbound GitHub access for mirror refreshes; visitors do not. Deploy `update-signing-public.pem` with the website runtime files. Keep its matching private key outside the site and repository.

## Deployment

Install `requirements.txt` in `/opt/bobtv/venv`, deploy the runtime files from this `website/` directory to `/opt/bobtv/site`, create user `bobtv` and writable `/var/lib/bobtv`, then install the systemd service and timers. The `website/docs/` and `website/tests/` directories are source and verification artifacts, not runtime data. Before restarting a site version with the source registry, run `BOBTV_DATA_DIR=/var/lib/bobtv /opt/bobtv/venv/bin/python /opt/bobtv/site/migrate_source_reports.py` as `bobtv`. Before enabling candidate intake, likewise run `migrate_source_candidates.py` as `bobtv`. Both migrations create separate versioned databases and are idempotent; older code ignores the new candidate database on rollback. During first issuance use `deploy/nginx-bobtv-bootstrap.conf` and `certbot certonly --webroot -w /var/www/bobtv-acme -d bobtv.briconbric.com`. Replace the bootstrap with `deploy/nginx-bobtv.conf` after certificate issuance. Validate `nginx -t`, reload, and verify origin and Cloudflare TLS separately. The independent BobTV certificate leaves the shared `briconbric.com` SANs and renewal behavior intact. Do not publish the site until the release mirror and certificate both verify.

Run `python -m pytest website/tests` from the repository root with `fastapi`, `httpx`, and `pytest` available. Flutter checks remain `flutter test` and `flutter analyze`.
