# Regional route selection

## One inventory, multiple network observations

The public `routes` table and canonical SHA-256 URL identity remain the source
of truth. Categories, provenance and explicit retirement are shared globally.
`route_network_health` stores observations by route ID, country, subdivision,
ASN, day and reporter. It does not create regional copies of a route.

The server gateway introduces `transport: server-relay`. Its observations live
in `relay_route_network_health`, separate from historical direct-connection
measurements. The ranking request includes that transport, and the desktop local
score context ends with `|server-relay`. Original route URLs and global
retirement identities stay unchanged. Server relay scores describe the complete
client-to-gateway-to-origin path. Mainland reachability still needs measurements
from an actual mainland network and a reachable gateway.

Network failures are regional observations, not retirement. A verifier running
in one network can no longer remove previously reviewed routes from the public
snapshot after three failures or seven days. A polluted route explicitly
retired by a viewer remains blocked in every region and cannot reappear through
rediscovery. Automatic global dead-route removal requires independent regional
evidence; it is deliberately not inferred from one overseas verifier.

## Profile and ranking APIs

`GET /api/v1/channel-catalog/network-profile` determines the current connection's
coarse country/subdivision/ASN using local DB-IP Lite MMDB files. It returns
`schemaVersion`, `countryCode`, `regionCode`, `asn`, `networkId`, `issuedAt`,
`expiresAt`, `token`, `approximate` and DB-IP attribution. It never returns the
viewer IP, coordinates, device name or playback history. Geography is an
approximate network label, not a statement of channel identity or residency.

Only the trusted reverse proxy may provide the connection address. Cloudflare
country attribution is accepted only from configured Cloudflare peer ranges.
Client-supplied country, ASN and arbitrary forwarding headers are ignored.
Uvicorn must retain `--forwarded-allow-ips 127.0.0.1`, and nginx must replace
incoming X-Forwarded-For with its actual trusted peer address.

`POST /api/v1/channel-catalog/rank` takes `schemaVersion: 1` and 1 to 200 public
`urls`. It determines the request's current network, returns its signed profile
and existing nonretired candidates with `score`, `confidence`, `scope`, sample
and independent reporter counts, decoded-playback confirmations and optional
first-byte/throughput measurements. Unknown candidates remain neutral and must
not be hidden. No remote media request runs inside this API.

Ranking uses exact subdivision + ASN first, then country + ASN, subdivision,
and country. It never borrows observations across country boundaries. Coarser
fallbacks have less influence. Sparse, single-client evidence has reduced
confidence; 28-day observations decay toward neutral. A single reporter has a
20-vote per-route/network/day budget. This limits accidental noisy observations,
but anonymous fingerprints are not authentication and cannot by themselves
provide Sybil-resistant voting. A malicious-report defense requires a separate
reviewed identity or probe trust policy before automatic global retirement.

Health events on the existing `/events` API may include `networkToken`,
`observation` (`probe`, `playback`, `stall`, `manual`), `firstByteMs` and
`bytesPerSecond`. Existing success/failure fields and event receipts stay
compatible. A signed token captures the network when the event is queued, so
reconnecting from another country does not relabel offline observations. Tokens
expire after seven days; expired/tampered reports are rejected. Legacy reports
are unattributed and never influence a country's ranking. Attributed votes do
not change the old global counters. Transport probes carry less positive weight
than decoded playback. Observations never approve a new unreviewed route.

## Desktop integration

Windows and macOS use the same Dart service. It refreshes the connection profile
in the existing one-minute sync cycle and requests rankings only for candidates
of the selected channel. Short-lived caches and API failure backoff avoid full
catalog scanning. Player preparation waits at most 600 ms for the website, then
continues with local observations and unknown candidates. Late replies only
update scores; playback generations still control channel changes. Main playback
and card preview share this path.

Local playback metrics are also keyed by network ID. Historical unlabelled
metrics stay in the unknown network and do not follow a user into another
country. Local observations carry 75% of the combined score when present.
Successful decoding raises the score; stalls and manual next-route actions
lower it. Explicit retirement continues to synchronize globally.

## Local databases and operation

Install `website/requirements.txt`. Run `update_network_databases.py` as `bobtv`
to load the current official DB-IP Lite city and ASN databases. Downloads use
verified HTTPS, bounded decompression, MMDB validation and atomic replacement.
No per-viewer address is sent to a third-party geolocation API. Install the
`bobtv-network-db.service` and `.timer` units for monthly refresh. Geo files live
under `/var/lib/bobtv/network-db`, or `BOBTV_NETWORK_DB_DIR`; the token signing
key is `/var/lib/bobtv/network-profile.key`, mode 0600. Retain the key across
deployments. The existing daily SQLite backup includes regional observations.

Data attribution: [IP Geolocation by DB-IP](https://db-ip.com), DB-IP Lite,
CC BY 4.0. Any website UI displaying derived results must include that link.
Missing, invalid or unavailable MMDB data falls back to an unknown profile and
local selection. Network lookup is advisory, not an access restriction.

## Verification boundaries

Automated tests cover China/overseas isolation, different ASNs within China,
neutral fallback, bounded/idempotent voting, token expiry and tampering, shared
retirement, old client compatibility, reverse-proxy spoofing and retained routes
after one server's failures. Mainland ISP measurements require a real mainland
network. Until such measurements arrive, a source must not be advertised as
mainland-verified. VPN or proxy use makes the detected profile describe that
egress network; local measured playback remains the deciding evidence.

Regional ranking alone does not relay video, bypass authentication or geographic
rights, or accelerate website/API/download delivery. The separate egress gateway
now relays reviewed public media. Trusted mainland probe nodes and
authorized regional media delivery can be added without changing route identity.

## Trusted regional probe enrollment

`GET /probe-targets?nodeId=...` and `POST /probe-results`, beneath the same
channel-catalog API prefix, require a registered private bearer token. The
administrator's `/etc/bobtv/network-probes.json` maps `nodes` to their
`keySha256`, `enabled`, `canApprove`, `countryCode`, `regionCode` and `asn`.
Only the secret's hash is stored centrally. A node's configured network must be
verified during enrollment. Ordinary clients cannot enroll or approve routes.

`network_probe_agent.py` can run on each controlled regional node with a private
`/etc/bobtv/probe-agent.json` containing `baseUrl` (HTTPS), `nodeId` and `token`.
It requests up to 100 pending/stale targets, checks actual media bytes with the
existing SSRF-safe verifier at four-way concurrency, and submits idempotent
results. Authenticated API requests forbid redirects. Transport checks are
labelled `probe` and do not claim decoded/sustained audio and video. A future
controlled decoder probe may submit distinct `playback` evidence.

Successful approved-node evidence can validate a previously pending domestic
route even when the central overseas verifier cannot reach it. Failed evidence
changes only that node's regional score. Retired routes are never revived.
An observer node with `canApprove: false` can measure existing routes without
publishing new ones. Reusing a result ID with changed content is rejected. No
mainland node is enrolled automatically or simulated as a real measurement.
