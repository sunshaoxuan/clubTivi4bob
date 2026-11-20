# Route-scoped managed EPG

Optional administrator-reviewed mapping evidence:

```json
{
  "routeScopeExplicitlyReviewed": true,
  "routeScope": [
    {"routeId": "route-example", "urlSha256": "64 lowercase hexadecimal characters"}
  ]
}
```

This extends the existing evidence fields and does not grant programme-data
rights. The scope must be nonempty, sorted by route ID, unique, and match the
current public catalogue's exact IDs and SHA-256 of the unmodified URLs.
Approvals still require exact channel, country, region and delay-version review.
Locked approvals cannot have their scope silently widened or removed.

Ingestion and publication revalidate the current route addresses. A removed or
changed route fails closed without deleting the approval, private programme rows
or raw caches. New unrelated routes do not join an existing scope. No database
migration or rewrite of existing unscoped mappings is required.

Scoped public guides use a synthetic `route-epg-<sha256>` ID. Its material is the
parent channel ID, parent identity hash, and sorted `routeId:urlSha256` lines,
joined by LF with no trailing LF. `routeBinding` contains schemaVersion=1,
catalogChannelId, catalogIdentityHash, and routes. The standard public identity
hash describes the synthetic identity; programmes reference that synthetic ID.
The common receiver checks both fingerprints and the exact local route address.

Legacy receivers accept the v1 envelope but cannot join a scoped synthetic ID
to a catalogue channel. Other existing guides remain usable. Current clients
require a new application build to receive scoped guides. The shared Dart
implementation serves macOS, Windows and Android; this is not a client release.

Playback route changes trigger an EPG-only refresh of fullscreen and inline
programme views. The runtime resolver rejects a scoped guide when the active
stream address differs, even before the next reconciliation. It does not call
video open, mute, seek, channel selection or scroll controls. Manual/locked and
private-source mappings are preserved.

Validation includes route exclusion, address drift, scope tampering, locked
scope protection, retained cache, legacy-safe IDs, live-source lookup,
channel-wide-to-scoped updates, two-version receiver transactions and scoped
published coverage. Fixtures use synthetic schedules, not invented real EPG.

No NHK schedule is approved by this change. The 2026-11-18 investigation found
zero NHK World network1096 episodes in licensed TVmaze date responses for
2026-11-18 through 2026-11-24. NHK-direct redistribution rights remain unverified.
NHK World Premium, domestic NHK and unknown relay editions stay separate.

Validation on 2026-11-18: Android ARM64 debug APK compiled, shared receiver and
runtime tests passed with serial execution, and the focused Dart analyzer was
clean. A parallel run exposed an existing database-notification timing failure;
the same suite passed serially. Native macOS compilation stopped because the
host lacks CocoaPods. No Windows native build or physical-device playback was
performed in this change. Real-production cache replay tests require a fresh
capture and were skipped; synthetic regression results do not replace those
checks. No official binaries, update feeds or GitHub Release are published here.
