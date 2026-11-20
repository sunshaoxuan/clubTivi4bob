# Deployed catalog source

This directory records the classification source actually owned by the ccnode
server at `/opt/bobtv/site`. `source-manifest.json` records the initial live
baseline. Some live modules were absent from repository main; several shared
filenames differed from `website/`. Preserve the independent changes in
`website/` when reviewing and integrating this server branch.

The broadcast-market hotfix deploys the files listed in the recorded deployment
plan, with the market policy and audited registry from `website/`. It does not
build or release application packages. Future deployments that replace these
filenames must retain the SQLite review holds and publication barrier, or
explicitly migrate them after a reviewed comparison against the live hashes.

Pending holds freeze shared country, region and category for exact channel
identities and route contexts. Health and unrelated metadata continue to update.
Identity or route context changes remain held. Historical manual flags do not
unlock a hold. An explicit user classify action is audited separately; official
market approval uses `market_review_admin` and verifies every active member route
before its audited release transaction. Client-private classifications are
outside this server inventory.

The hold queue contains detected ambiguous/conflicting channels. This change
does not claim official identity evidence for every catalog entry or globally
freeze every future unflagged channel. A newly detected finding enters the
shared inventory hold path; a pre-existing hold persists after weak indicators
change or disappear.

Validation uses the three focused test modules and full production-inventory
clones with control/candidate republication. Deployment records source hashes,
SQLite and file backups, baseline geography comparisons, transaction completion,
and public compressed-snapshot verification.
