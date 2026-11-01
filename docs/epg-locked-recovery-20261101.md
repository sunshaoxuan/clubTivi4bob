# Locked public EPG recovery

`epg_locked_recovery.py` connects missing coverage on approved, locked public
channels to the existing persistent source-discovery worker. It shares the
authoritative database, serial batch limit, model admission, durable leases,
bounded public HTTP checks and exponential search backoff.

Admission requires a current data grant and mapping fingerprint, a fresh
channel-bound coverage gap, and expired coverage or sustained source failure.
A healthy off-air interval with future programmes does not qualify. Full
station identity, operator, country, frequency/number, language, region/delay
edition, category and exact route evidence remain necessary before programme
source search. Recovery cases take priority over unserved catalogue research.

The dedicated `epg_locked_recovery_jobs` scope permits research only. All other
discovery consumers retain their original mapping protection. Recovery cannot
overwrite or revoke a locked mapping, grant permission, change programmes,
delete historical data, replace caches or publish an unvalidated snapshot.
Candidate sources enter the existing channel-bound validation/review queue.
Source code licences do not grant programme-data reuse. A replacement needs
separate exact-feed and explicit programme-data permission checks.

`enabled=0` disables a recovery scope and survives subsequent synchronization.
Revocation, source-rights changes, catalogue/route/category changes and actual
coverage recovery invalidate in-flight research. Source and search retry
floors survive synchronization and worker interruption. Registered failing
source URLs, redirect URLs and the reviewed Taipei monthly metadata address
are not requested before their existing upstream retry deadline.

## Verification and deployment

Offline acceptance is in `website/tests/test_epg_locked_recovery.py`, alongside
the existing auto-search, identity review, schedule, ingest, store and coverage
tests. Fixtures do not authorize production mappings or programme data.

Commit and push tested changes to `publish/main` before deployment. Stage the
four runtime modules together, verify their hashes and compiled imports, and
replace them only while the source-discovery and schedule workers are idle.
Keep previous modules for rollback; leave APIs and the other EPG services
running. Restore the existing timers, inspect the ordinary worker execution
receipt and durable recovery/search audits, and verify both public nodes.
No new database, server timer, client release or device restart is required.

On 2026-11-01 the previously approved Taipei monthly CSV has no verified
November resource. Its October rows must remain expired historical cache.
The dated FM website schedule is a permission-review candidate, not an
approved replacement. Deploying this bridge does not itself restore coverage.
