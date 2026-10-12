# BobTV resource nodes

## Transport and identities

The canonical origin remains `https://bobtv.briconbric.com`. The fixed resource
relay is `https://cndrp.com/bobtv`. API results, catalog IDs, route URL digests,
publisher signatures and update manifest archive URLs retain canonical identity.
Only the network request URI is changed. Every client platform uses the same
resource router, including raw dart:io, package:http, Dio and cached images.
The download page and manual diagnostic upload page use a browser equivalent
with restricted CORS from the canonical website. Read-only failures can fall
back once; a failed browser upload is never automatically replayed.

Before its first resource request, a client concurrently reads an identical
65,536-byte uncompressed probe from both nodes. Valid node identity, body
contents and completion within three seconds are required. Full response time
includes connection latency and sample transfer. The faster successful node is
selected for ten minutes, then compared again. A connection/TLS failure selects
the alternative before headers or an upload body are sent; the failed node has
a one-minute cooldown. Uploaded bodies are never blindly replayed after sending.
HTTP 502/503/504 and response-connection failures also change the next selection.
Only GET/HEAD can retry automatically after a request has been sent.
The existing persistent client outbox retains failed mutation events and stable
receipt IDs for later deduplicated retries.

## Cache and data consistency

Only public package files, immutable channel snapshots and approved metadata
paths can be cached. The bounded Nginx disk cache has an 8 GiB target maximum,
cache locking and revalidation. Upstream `private`, `no-store` and authentication
headers prevent shared caching. Latest update feeds, catalog manifests, sync
events, geography profiles, rankings, AI results, uploads and diagnostic receipts
always reach the canonical service. All mutation methods bypass caches. No
independent writable catalog database is created on cndrp.

The relay sends client attribution authenticated with a private server-only
HMAC, node address, method, path and a timestamp valid for sixty seconds. The
origin verifies the registered peer, including its existing trusted Cloudflare
boundary when applicable. Client-supplied forwarding headers cannot change
country, ISP, rate limits or fingerprints. Node secrets are outside the repo.

The deployed relay connects to the administrator-configured origin IP with
canonical `Host` and TLS SNI `bobtv.briconbric.com`, retaining full certificate
verification. It never downgrades TLS or follows upstream redirects. This avoids
reintroducing Cloudflare on the relay's origin leg. Origin address changes require
updating `BOBTV_RELAY_ORIGIN_IP`; clients fall back when the relay probe fails.
This transport uses the documented [HTTPX SNI extension](https://www.python-httpx.org/advanced/extensions/).

## Video exclusion

Video manifests, segments, keys, recordings, main playback, card preview,
failover probes, multi-view and casting use the video source directly. Media
URLs already wrapped in the old BobTV media gateway are unwrapped first.
Required User-Agent/Referer/Origin headers are preserved. The resource node
rejects `kind=media`, and the native sender rejects its `/bobtv/` URLs. Regional
playback observations use `transport=direct`; old gateway observations remain
isolated. GitHub discovery, source document refresh and AI requests remain
server-owned resource operations, with no client-side discovery fallback.

## Deployment

`tools/deploy_resource_relay.py` backs up and modifies only the named BobTV API,
relay unit and cndrp custom include. It preserves localized origin routes, mail,
Nextcloud and the existing cndrp homepage. Mail-in-a-Box's supported
`/home/user-data/www/cndrp.com.conf` include survives regeneration.

Prepare Linux Python 3.10 offline wheels in
`outputs/BobTV-resource-relay-wheels` before deployment. Include exceptiongroup
and importlib-metadata for Python 3.10 even when preparing wheels on Python 3.12.
The runtime is isolated under `/opt/bobtv-relay/venv`; system Python packages and
global package sources are unchanged. Reuse `--relay-only` for relay maintenance
without restarting the origin API. Existing running desktop apps are untouched.

Tests: `test/resource_node_router_test.dart`, `test/server_egress_test.dart`,
`website/tests/test_resource_relay.py`, and the existing API/update/regional suites.
Mainland performance requires actual mainland-network measurements. This server
deployment alone does not update already installed client binaries.
