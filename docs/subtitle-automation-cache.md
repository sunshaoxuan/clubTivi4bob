# Automatic subtitle delivery

Clients request programme-bound subtitle sessions only from BobTV nodes and
relays. Discovery adapters, persistent files and speech alignment run on the
server. The present adapter retrieves existing subtitle files. It does not call
GPT. Any future GPT-assisted discovery belongs behind a server-side provider;
clients must not receive its credentials or require connectivity to GPT.

The player reports searching, media warming, synchronization, temporary absence,
service failure, programme identity gaps, insertion suspension and English
fallback in all seven application languages. Silent dialogue gaps keep the
matched file available. Insertion status follows decoded playback position.

Cold sessions continue polling discovery while the original stream plays.
Once a matched language and normalized media are ready, a guarded automatic
connection first opens a separate muted decoder. Promotion requires decoded
frames, advancing playback, and at least eight seconds of buffered media. Failed
preparation leaves the original decoder playing. Old response generations and
superseded channel selections are rejected. A media failure falls back to the provider and cools
auto-connection for five minutes while discovery/status polling continues.
Expired sessions and missing programme information retry automatically.

Subtitle resources live in `/var/lib/bobtv/resource-cache/subtitles`, outside the
two-hour private-media cleanup. A validated IMDb identifier is preferred;
official market/movie IDs are retained as aliases. Title plus year is the
fallback identity, normalized with Unicode. Identity conflicts remain errors
rather than merging unrelated films. Every edition and language has its own
record; raw SRT bytes are content addressed and hash checked. Matching English
cue grids are required for translated tracks. Concurrent viewers share one
lookup, cached languages survive restarts, corrupt resources are fetched again,
and transient provider failures retain usable cached English. Negative results
expire. Matching historical session downloads can be imported automatically.

Movie identity, subtitle files and provenance are reusable. Programme-relative
live offsets and ad calibration are not persisted as reusable cache entries.
New sessions still establish their own verified media timeline.

Deployment starts the v2 service on loopback port 8922, separately from the
existing service on 8921. Unknown legacy session/media tokens are forwarded to
the old process so active viewers can finish. `--stage-only` tests the v2 service
without changing the public Nginx route. Rollout retains rollback files.

IMDb-bound secondary lookup now uses SubDL's public search and existing ZIP
resources. Each result must have an unambiguous IMDb query result, complete
original title and exact year. All seven language containers are inspected;
translated tracks still require a verified matching English clock grid. Normal
provider Referer headers accompany downloads. Provider errors do not prevent
trying another source. Complete title matching also rechecks older cache entries,
so a longer film title sharing a prefix cannot poison another IMDb identity.
After three speech windows fail every candidate, the API reports no usable file
while continuing later acoustic attempts; it no longer promises indefinite
synchronization. A later successful lock restores normal delivery automatically.
