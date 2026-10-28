# National genre favorites identity correction

Date: 2026-10-26 (Asia/Tokyo).

The channel presentation key previously collapsed national television root
categories but retained standard domestic genre leaves as identity boundaries.
A read-only backup of the installed database reproduced First Theater as two
favorite cards across 中国 / 央视 and 中国 / 数字 / 剧集.

The shared presentation key now recognizes a single known genre leaf beneath
央视, 数字 and 卫视 as classification membership. Both public routes and legacy
provider bridges use the same rule. Favorites, route counts and merge selection
therefore use one service identity across these paths. Existing favorites are
reconciled by the existing database mechanism without deleting source rows.

Regression coverage includes 36 root/genre combinations, conflicting countries,
regions, guide IDs, UHD, radio, custom/deeper paths, restored favorite memberships,
adding from either category or a legacy provider, canonical URL deduplication,
cross-category removal and re-adding. The installed backup replay changed 11
favorite route records from two cards to one. The live database was not written.

Source changes are limited to channel_presentation_identity.dart and its channel
card regression tests. No package, installed client, public release, website or
server deployment was changed as part of this correction.

Validation receipts: BobTV-favorites-20261026/final-regression.log and analyze.log
under the local release outputs directory. The initial failing reproduction is
retained separately. A regression invocation using a nonexistent test filename
was corrected to stream_alternatives_service_test.dart before the final run.

Final validation: 68 tests passed, one unrelated backup-gated test skipped;
focused static analysis reported no issues.
