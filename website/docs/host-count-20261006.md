# Hardware-host fingerprint correction, 2026-10-06 JST

## Scope and identity

This change corrects repeated-install host counting. Channel-sync installation
identity, playback, updater, installers, release versions and feeds are unchanged.
The latest continuation explicitly limits work to fingerprint management.

Hardware UUID is normalized and SHA-256 hashed with `BobTV-host-v1|uuid`, prefixed
`bth1_`. Preferences, OS user, platform salt and installation salt are excluded.
Windows uses WMI SMBIOS UUID; macOS uses IOPlatformUUID. Matching valid hardware
UUIDs produce matching host identities across fresh reads and supported platforms.
Invalid/default UUIDs fail closed without random replacement. Raw UUIDs never
leave the host. Existing installation fingerprints stay independent.

The separate version-1 registry has a unique host key and serialized idempotent
registration. Migration is explicit, transactional and repeatable. Reads never
create a database. The old 45 salted installation IDs remain in channel storage
and are excluded from the host statistic; they cannot be reliably backfilled.
Page count refreshes every 30 seconds, on visibility return and network recovery.
Unavailable counts are omitted. Registration has bounded body, rate and capacity.

## Executed checks

- Final Flutter identity/API suite: 14 passed, including two real Windows hardware
  reads posting the same identity to a local-only HTTP server.
- New host service/test static analysis: no issues. Earlier affected-file analysis
  had no errors/warnings and 20 existing style notices in the API client.
- Final registry tests: 26 passed on Windows and 26 on isolated Linux. They cover
  concurrent deduplication, different identities, legacy exclusion, invalid input,
  bounds, capacity, corrupt data, unavailable schema and future-schema rejection.
- Earlier Linux affected site/inventory/event suite: 89 passed. The final connection
  cleanup was followed by the focused 26-test suite, not a repeat of that whole suite.
- Localization after preserving current production copy: 46 passed. Production
  already had 1.0.3 product text; that text was retained when adding the hash notice.
- Local browser: timed count changed from 1 to 2 without page navigation; synthetic
  503 removed the suffix and an online event restored it. Test identities stayed local.
- Local and production browser: 36 combinations each, four languages, three pages,
  widths 1440/390/320. No horizontal overflow, page errors or failed requests.
  Production also had no console errors.
- Production aggregate endpoint returned HTTP 200 with count 0; service is active.
  No synthetic identity or raw hardware data was registered in production.
- Gemini Pro High and latest Flash High image requests had no available accounts.
  Agent reviewed actual desktop/mobile screenshots; external visual approval is absent.

The Linux environment emits one upstream TestClient deprecation warning.
macOS command output has fixture coverage; physical macOS execution is unverified.
Ignored local test artifacts remain under website/.test-output following the earlier
cleanup restriction. They are excluded from Git and were never deployed as runtime.

## Deployment and limits

Website runtime is deployed on CCNODE under `/opt/bobtv/site`. Backups:
`/opt/bobtv/backups/site-before-host-registry-20261006.tar.gz` and
`/opt/bobtv/backups/device-registry-before-closefix-20261006.py`.
The deployment wrapper first rolled back after a trailing CR parsing error; its
successful rerun and final fingerprint-only patch were checked at origin and public URL.
Restore the website archive and restart bobtv to roll back; the new standalone
registry remains separate and is ignored by old website code.

Current published desktop packages do not contain this new registration code.
No installer release was performed. Count 0 is the new registry's observed coverage,
not a claim that nobody has installed BobTV. A later authorized client release is
needed to begin reporting. This branch must be integrated with the current release
source before any future packaging; it must not replace the existing 1.0.3 packages.

Duplicate vendor UUIDs or cloned VMs can merge hosts. Changed firmware identity
can create a new identity. Public registration has no installation attestation.
This is cumulative pseudonymous telemetry, not an exact physical-host census.

Screenshots: [desktop](host-count-20261006/production-desktop.png) and
[mobile](host-count-20261006/production-mobile.png).
