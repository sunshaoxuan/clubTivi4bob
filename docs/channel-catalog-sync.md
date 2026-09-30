# BobTV channel catalog synchronization contract

This document defines the implemented website contract for fast first launch. It
does not replace the existing `/api/v1/sources` endpoint, whose reviewed-source
directory currently has a different schema and may legitimately be empty.

## Publication model

The website prepares the catalog ahead of time. Its database stores a stable
channel identity, display name, preassigned category, country or region, sort
position, EPG mapping, logo and one or more reviewed public routes. Route
provenance, last successful verification time and health score stay associated
with each route. User subscriptions, authentication parameters, local network
addresses, playback history and device identifiers must never be published.

The website publishes a complete, immutable catalog snapshot only after all
records have passed validation. A failed or partial generation keeps the
previous snapshot available. Channel and route IDs must remain stable between
snapshots so favorites, retired routes and local health history survive updates.

## Public API

`GET /api/v1/channel-catalog/manifest` returns a small JSON document. The
server should support `ETag` and conditional requests. An example follows:

```json
{
  "schemaVersion": 1,
  "version": "2026-09-27T12:00:00Z.1",
  "generatedAt": "2026-09-27T12:00:00Z",
  "channelCount": 2000,
  "routeCount": 30000,
  "snapshotUrl": "/api/v1/channel-catalog/snapshots/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json.gz",
  "compressedBytes": 2500000,
  "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
```

`GET /api/v1/channel-catalog/snapshots/{sha256}.json.gz` returns an
immutable gzip-compressed UTF-8 JSON document. `sha256` is calculated over the
compressed response bytes. The response should be cacheable for a long time.
The client rejects a mismatched hash, unsupported schema, duplicate IDs,
oversized document or invalid record before touching its existing catalog.

```json
{
  "schemaVersion": 1,
  "version": "2026-09-27T12:00:00Z.1",
  "categories": [
    {"id": "cn-cctv", "parentId": "cn", "name": "央视", "sortOrder": 10},
    {"id": "cn", "parentId": null, "name": "中国", "sortOrder": 10}
  ],
  "channels": [
    {
      "id": "cctv-5-plus",
      "name": "CCTV-5+ 体育赛事",
      "categoryId": "cn-cctv",
      "countryCode": "CN",
      "regionCode": null,
      "sortOrder": 25,
      "epgId": "cctv5plus",
      "logoUrl": null,
      "routes": [
        {
          "id": "example-route",
          "url": "https://media.example.org/live/cctv5plus.m3u8",
          "source": "reviewed-public-source",
          "lastPlayableAt": "2026-09-27T11:50:00Z",
          "healthScore": 0.8
        }
      ]
    }
  ]
}
```

The example values do not represent a real playable route. The server must
distinguish CCTV-5 from CCTV-5+ with separate stable IDs and EPG mappings.
Category IDs form a tree. Countries or regions may be first-level categories;
the client displays the server's order and labels without reclassifying every
route on startup. If a category cannot be resolved, the website explicitly
assigns an `unknown` category for later editorial review.

## Client startup and synchronization

The first frame uses the last valid local catalog, or a small packaged starter
catalog on a new installation. It never waits for network access or a full
route scan. In the background, the client fetches the manifest and downloads a
snapshot only when its version changes. It decompresses and validates away
from the UI thread, then imports records in bounded batches into a staging
area. A single final transaction makes the complete new catalog visible.

The import preserves local favorites, hidden channels, retired routes and
route weights. Website defaults never overwrite these local decisions. A
network failure, invalid snapshot or empty publication leaves the last valid
catalog usable. Progress reports include downloaded bytes and imported channel
count. Route verification starts after the catalog is visible and favors the
currently viewed category. New channels appear without rebuilding the entire
visible list on every result.

The current application has a bundled GitHub route snapshot and a separate
`/api/v1/sources` reviewed-source client. The new catalog must be kept in its
own provider or tables during migration. Existing local sources continue to
work until the website catalog is populated and verified. The GitHub crawler
remains a source-discovery mechanism; candidates enter the public catalog only
after review.

## Installation inventory and verification

Every Windows and macOS installation uploads public channel metadata to
`POST /api/v1/channel-catalog/inventory` in pages of at most 200 routes.
The JSON body includes `schemaVersion: 1`, a 64-character application-scoped
`fingerprint`, and `routes`. Each route contains `name`, `url`, `group`,
`source`, optional `epgId`, `logoUrl`, `playableAt` (Unix seconds), and `blocked`.
Successful unchanged pages are checkpointed and skipped on later runs.
Failed pages retry automatically. Private and credential-bearing URLs and
obvious platform livestreams are excluded. Classification uses saved AI results
where available; unresolved channels remain in the explicit unknown category.

`bobtv-catalog.timer` starts the verification worker every five minutes.
Verification follows HLS playlists to actual media bytes, with bounded
concurrency, timeouts, and public-address checks. Recently verified routes are
published atomically. CCTV-5, CCTV-5+ and 4K variants retain separate identities.
Clients download revisions every fifteen minutes. Initial server verification
records seed local availability, so a fresh installation does not have to
recheck every route before showing its cards.

`GET /api/v1/channel-catalog/blocked` returns `schemaVersion: 1` and `urls`.
Retirement is monotonic: later inventory uploads cannot restore that URL.
Clients apply these tombstones to all providers, including bundled sources.
The old manifest remains available if generation fails. Deploy the timer and
service files under `website/deploy` alongside the updated website runtime.

## Acceptance checks

Verify an empty server, offline launch, interrupted download, hash mismatch,
duplicate channel and route IDs, a removed channel with local favorites, a
retired route reappearing in a later snapshot, and a large catalog on a fresh
installation. The first usable category should appear before background route
verification completes. Measure time to first frame and time to first playable
channel separately.
