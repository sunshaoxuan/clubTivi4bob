# Whole-catalog channel grouping and merge picker validation

The fix applies to channel identities across the catalog. Wind Theater is a
regression sample, not a production special case.

## Verified against an installed database backup

The installed SQLite database was read only to create the backup. Replay and
schema initialization ran on that backup, without replacing or restarting the
installed application.

- Source records: 22,050, all retained.
- Display identities across the inventory under the old grouping: 13,937.
- Display identities under the updated grouping: 12,865.
- Normalized-name groups with fewer display identities: 1,051.
- Wind Theater across all sources: 8 records, 1 display identity, 5 canonical URLs.
- These inventory totals are not a screenshot count for any one category.

## Digital category samples

| Channel | Source records | Visible identities | Canonical URLs |
| --- | ---: | ---: | ---: |
| 风云剧场 | 2 | 1 | 2 |
| 风云足球 | 1 | 1 | 1 |
| 风云音乐 | 5 | 1 | 5 |
| 女性时尚 | 2 | 1 | 2 |
| 兵器科技 | 7 | 1 | 7 |
| 第一剧场 | 6 | 1 | 6 |
| CETV1 | 10 | 1 | 10 |
| CETV2 | 6 | 1 | 6 |
| CETV4 | 4 | 1 | 4 |

## Behavior

- Same-service domestic catalog records share an identity across national genre
  categories, including old unprefixed domestic category names.
- Known international country identities share an identity across automatic
  genre categories, such as news and general programming.
- Unicode letters, marks and digits survive name normalization. Cyrillic,
  Arabic and Greek services no longer lose their identifying name text.
- Canonical URLs are deduplicated for display counts and alternative playback.
- Merge choices use the same identities as cards; display-name equality does
  not disable another selection. Selections are revalidated before review.
- Search and pagination reuse the picker snapshot; review reloads identities.
- Country, regional context, distinct guide IDs, UHD, radio, delayed versions
  and manual decisions remain identity boundaries. Catalog context is imported
  atomically and backfilled on upgrade even if the catalog version is unchanged.

## Validation

- Complete Flutter test directory: 755 passed, 21 environment-gated cases skipped.
- Whole installed-catalog backup replay, with assertions for all nine listed
  digital-category samples: passed separately with its fixture enabled.
- macOS debug application: built successfully after the global grouping changes.
- Targeted static analysis: no errors or warnings; two brace-style info notices.
- Git whitespace/conflict-marker check: passed.

## Limits

The audit still contains 833 normalized-name groups with multiple identities.
This includes real country, regional, television/audio, guide and version
boundaries, plus records without enough metadata to establish equivalence.
That number is not a count of verified duplicate services. For example, older
Phoenix entries in Other have distinct public IDs, lack country/region context,
and do not share an endpoint with the classified Hong Kong catalog records.
They remain separately selectable in the repaired merge picker.

No installed application replacement, public release or server deployment was
performed. A macOS debug application was built. Tests and build logs are stored
under `/tmp/bobtv-channel-fix-20261022/` for this run.
