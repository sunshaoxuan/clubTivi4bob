# Broadcast-market classification result

Reviewed policy: use the exact channel edition's broadcast market, supported by
official provider identity and every active route. Country of incorporation,
programme origin, spoken language, playlist source geography and an EPG token
alone do not establish that edition. Conflicting or incomplete evidence stays
pending; private client classifications are outside this shared-inventory work.

Action Movies (service 6065) and Romance Movies (6194) were changed from US to GB,
with category paths changed together from 国际 / 美国 / 电视 / 电影 to
国际 / 英国 / 电视 / 电影. Their IDs, EPG identifiers, public URLs and manual flags
were preserved. An unpublished Romance member remains unpublished. There are no
EPG mapping approvals or private client edits.

The other 130 findings retain their existing country, region and category:
122 explicit EPG edition suffix conflicts, 3 Rakuten identities whose alternative
routes lack a complete official binding, 2 category versus country-code conflicts,
and 3 country-label scope differences. The 3 Rakuten rows each have both a
provider-host and EPG indicator; the indicator counts therefore overlap.
The earlier audit's 5 false indicators (SD quality tokens and UK/GB alias handling)
were removed before the 132-identity review set and 2 proven corrections.

Persistent SQLite protection now covers the 130 identities and 143 route
contexts. Matcher inference, taxonomy migration, source metadata refresh, cached
AI decisions and independent classification writers cannot change their shared
geography. Identity or route changes remain pending. Explicit classify actions
have their own audit record; official evidence approval independently verifies
all active routes and releases holds within the approval transaction. The final
publisher also protects against stale worker proposals and route rebindings.
Unrelated metadata and health writes continue; a live dry eligibility read found
8,892 other targets still eligible under the existing scheduler rules.

Before installation, all 130 were checked against the already published two-fix
baseline and no country, region or normalized category drift was found. All
9,098 public channel cards and 10,127 public routes remain exactly equal after
the protection deployment. Twenty-eight focused tests passed. Full inventory
control/candidate republication and durable direct-SQL probes passed with frozen
application commit 146887251eb96598599bcad7331771d55ed7c17e.

Runtime source is `/opt/bobtv/site` on ccnode, staged at
`/opt/bobtv/market-staging/cee579a98587`. The stage name identifies the first
protection commit; deployment input and hashes identify the final exact source.
Source is pushed to `fix/catalog-broadcast-market-20261115`. Repository main was
not merged, and no application packages were built. `production/catalog/` records
the actual server baseline, preserving independent `website/` changes. Future
server deployments must retain or deliberately migrate these protections.

SQLite and source backup:
`/opt/bobtv/backups/market-hold-20261115T105218Z`.
The previous two-channel correction backup remains at
`/var/lib/bobtv/market-review-backups/20261115T100839070362Z`.

During the protection deployment, root-owned atomic outputs with mode 0600 caused
an actual temporary HTTP 500. Only the new manifest, snapshot and review queue
were assigned to bobtv, retaining 0600. The deployment script now explicitly
sets their service UID/GID. The service identity successfully read all three,
internal HTTP recovered to 200, and a new complete external cndrp download passed.
The primary public hostname still returns local-network HTTP 403, as it did
before deployment; external acceptance is through cndrp.

Verified public version: `2026-11-15T10:52:22.162508Z`.
Compressed SHA256: `eeac9eeaa3b5edd2dfb895fdd85f82a9b1dc41717b65e80af908250c954402ee`.
`hold-public-verification.json` records the full byte/hash check and unchanged
130 pending cards, with both corrected channels still GB under the British path.

Boundary: this queue covers detected ambiguity and conflict. Existing holds
persist when weak hints disappear. Newly detected findings enter the common
inventory hold path. Unflagged future channels retain the legacy classifier;
this work does not establish official evidence or globally freeze every new
channel. The 130 queued identities are protected now and require an audited
explicit action or fully evidenced official approval to change geography.
