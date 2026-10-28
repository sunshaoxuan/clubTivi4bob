# Identity-stage programme-page gate

Date: 2026-10-24, Asia/Tokyo.

Daily inspection found a retained identity-stage search audit for LBC News with
a technical request to a third-party /tv-schedule/ page. The response was a 302
and was not followed. No mapping, data grant, programme or publication resulted.

The prior URL rule rejected /schedule/ but missed compound path segments such as
/tv-schedule/. Historical cached results also lacked a fresh phase-policy check.

## Change

- Decode URL path/query markers before identity-stage triage.
- Reject compound, encoded and query-selected EPG/programme/schedule locations
  while identity remains unconfirmed.
- Recheck the current phase policy before any HTTP-cache lookup or HTTP checker.
- Archive a hashed exclusion reason without deleting legal caches or old audits.
- Preserve technical station profiles and the existing post-identity programme
  discovery phases.

No generic parser, station mapping, licence grant or synthetic schedule was added.

## Verification and deployment

- Focused authored offline fixtures: 111 passed.
- Complete EPG test selection: 1,054 passed, one existing dependency deprecation warning.
- Server staged in-memory smoke: passed, including a forbidden HTTP callback,
  a retained historical cache row and allowed technical/profile paths.
- Atomic deployment at 2026-10-24 09:09:50 JST, with a verified previous-source
  hash for each file and a recoverable backup.
- API processes unchanged; no client, service or timer restart; no AI call or
  production database write by the deployment script.
- Locked mappings, data grants, audit history and existing retry floors preserved.

Backup:

    /opt/bobtv/backups/epg-identity-phase-gate-20261024.74rjj9g4

Deployment receipt:

    outputs/BobTV-epg-20261016/heartbeat-20261024T0910-phase-gate-deployment.json

The ordinary timer started a new worker at 09:11:32 JST. It completed at
09:12:46 JST with exit status 0 and a successful durable execution receipt.
Both deployed module hashes matched the tested files. No manual service start
was used. Live acceptance is recorded in
outputs/BobTV-epg-20261016/heartbeat-20261024T0913-phase-gate-acceptance.json.

This guard does not complete channel identity review, expand valid EPG coverage,
or establish cross-platform physical hot-update acceptance.
