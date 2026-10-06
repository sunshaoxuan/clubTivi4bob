# Device-count footer acceptance, 2026-10-06 JST

Request: append parentheses containing only an integer to the footer player label.
All pages/languages now include the server-side aggregate on each HTML request.
Actual production text at acceptance: BobTV · 开源桌面播放器 (45).

## Counting contract and privacy

COUNT(*) reads channel_inventory.sqlite3 / limits, which keeps one primary-key
reporter row per SHA-256-hashed existing application fingerprint. Inventory and
event submissions update the same row; rate-window resets and batch expiration
do not remove that identity. The current writer does not prune these rows.
The count represents cumulative observed client fingerprints, not visits, download
requests or recent activity. No new identity collection, public fingerprint API,
client modifications, database writes or migration were introduced.

Read-only production inspection found 45 reporter rows, 43 distinct recent batch
reporters and 4 distinct event reporters. These overlapping groups must not be
added. Only aggregate values were inspected; no fingerprint/IP was retrieved.
Unreported/offline installations are unknown. Reinstalling after identity reset
or multiple OS users can produce more fingerprints; cloned identity can merge
devices. Public intake has no installation attestation. This is not a verified
census of physical hardware. See README for the maintained metric definition.

Unavailable database means no displayed count, with a generic server warning.
A healthy empty registry displays (0). Read connections use SQLite mode=ro and
are explicitly closed; viewing the website never creates an inventory database.

## Executed verification

- Windows site/localization/counter tests: 67 passed.
- Isolated Linux site/localization/counter/inventory/events tests: 81 passed;
  one upstream TestClient deprecation warning. Linux-only fcntl dependencies
  prevented collecting the extra inventory/event tests on Windows; they ran
  successfully in the Linux environment. No runtime compatibility shim was added.
- Tests verify deduplication across repeat inventory and health events, separate
  fingerprints, batch expiration, 0-to-2 updates, missing/invalid schema,
  unchanged data on failed reads, all 12 page/language combinations and HEAD.
- Local browser with a synthetic 45-row registry: 36 combinations at widths
  1440/390/320 for four locales and three pages. Count was (45), no overflow,
  console errors or failed requests. Synthetic records stayed local.
- Public production browser: same 36 combinations returned 200 and (45), no
  overflow, console errors or failed requests. Desktop/mobile footer screenshots
  were reviewed by the main agent and retained alongside this record.
- Both changed deployed runtime files match local SHA-256; service active;
  all 12 explicit-language origin pages contain a parenthesized integer.
- Gemini Pro High and latest Flash each failed twice with no available accounts.
  External visual approval is unavailable; agent screenshot review completed.
- git diff --check passed. No production diagnostic logs or fake devices uploaded.

## Deployment and rollback

Changed only localization.py and templates/base.html in /opt/bobtv/site.
Prior production hashes matched Git baseline before mutation. Backup:
/opt/bobtv/backups/site-before-device-count-20261006.tar.gz.
Restarted the new page module before updating the template to avoid an undefined
template-variable window. Restore the two-file archive and restart bobtv to
roll back. The identity database and its data remain untouched.

Local server/browser closed. Remote test checkout, venv, data and upload archive
were cleaned up. Earlier local recursive-delete policy restriction remains;
ignored local .test-output files are retained, with no deletion bypass attempted.
The two footer images here are permanent acceptance deliverables.
