# Single-route transfer validation, 2026-10-12

## Delivery scope

The shared Flutter UI adds **转移线路到…** to main-player, preview-card and
fullscreen context menus. The picker searches across categories, paginates
results, disables the current channel and prevents repeated submissions. It
commits one canonical route locally before network work. Public edits use a
durable transfer event; private subscriptions stay local.

The origin API is deployed. No installed desktop app was replaced or restarted,
and no new installer or release was published in this task. Native Windows/macOS
visual and playback QA of this feature remains pending a rebuilt test package.

## Automated checks

- Flutter suite: 404 passed, 8 skipped, including the real isolated HTTP API
  cross-device test with three independent local databases.
- Follow-up targeted tests: 7 route-transfer tests passed, including the added
  private-account privacy test; picker and prepared-media checks also passed.
- Website suite: 142 passed, one existing Starlette/httpx deprecation warning.
- Picker interactions tested at 1100x850, 600x700 and 450x650 without overflow.
- Offline transfer/classification events retain their order and advance queued
  revisions after acknowledgement.
- Splitting a previous merge moves one route only; joining an existing merge
  inherits the destination identity. Verification history, provenance, health
  and tombstones survive. Old discovery and old-client inventory cannot revert
  the manually corrected ownership.
- Static analysis reports no errors. Existing unrelated warnings remain.

## Deployed evidence

- Verified SQLite and immutable-catalog backup:
  `/var/lib/bobtv/backups/server-20261012T053530566218Z`.
- Previous server code:
  `/opt/bobtv/backups/route-transfer-20261012T053530Z`.
- Only `catalog_inventory.py`, `process_channel_inventory.py` and
  `publish_channel_catalog.py` replaced. Live templates, translations, relay
  credentials and desktop processes remain untouched.
- `bobtv.service` active after restart; error-level journal showed no entries.
- Production checks sent a unique transfer event between two nonexistent
  synthetic URLs. Both canonical origin and relay returned HTTP 202, `retry`.
  No actual public route was moved and no synthetic route was inserted.
- Both public nodes served catalog version `2026-10-12T05:34:01.754428Z`,
  3800 channels and 4330 routes. The relay event response was `BYPASS`.
- Ordinary BobTV request headers succeeded. A default Python urllib user agent
  received HTTP 403 at the public edge, so production checks used the same
  BobTV request headers as the existing relay validation tool.

## Known limits

Automated UI layout is verified, but this is not a claim of native decoder or
installed-application acceptance. Fullscreen stops the transferred active route
and tries the original channel's remaining routes using the existing verified
replacement mechanism, without a global retirement or a health penalty.
