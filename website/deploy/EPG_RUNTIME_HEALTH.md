# Continuous EPG runtime checks

Existing validator, channel-first source discovery, ingestion and publication
timers keep their current frequencies. Install the independent
`bobtv-epg-runtime-health.service` and `.timer` after testing and pushing the
matching source commit to the BobTV main branch.

The watchdog runs every ten minutes as `bobtv`, after a one-minute startup delay.
It checks enabled/active timers, recent bounded worker execution, locally verified
published current/future coverage, approved source health and both public manifest
versions against the one authoritative database. Manifest requests bypass caches.
The publisher remains responsible for verifying both immutable snapshots before
activation. The watchdog does not fetch or parse programme upstreams.

An atomic private receipt is written to
`/var/lib/bobtv/epg/runtime-health.json`. Exit status 1 and structured issue codes
in the journal indicate degraded health. Successful idle oneshot services are
normal. A publication change during the network checks is recorded for the next
check without changing any activation pointer. This service does not send
notifications or automatically restart other services.

No SQLite migration, grant, mapping, programme cache or public snapshot is changed.
Permission/identity-blocked NCC, PTS, NHK and RTHK candidates remain blocked. This
monitor does not expand coverage or confer programme-data permissions.

To verify installation, inspect the timer's enabled/active state, run the oneshot,
read the receipt and inspect its journal. Stopping only the watchdog timer removes
the added checks without stopping EPG collection, refresh or publication.
