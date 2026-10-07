# Server-owned discovery and AI

BobTV clients use `/api/v1/server-tasks` for bounded metadata tasks. They never
send provider credentials, arbitrary prompts or an AI endpoint. POST returns
202 immediately for queued work and 200 for a cached result. GET by task ID
returns the asynchronous result. Existing catalog snapshots remain the playback
bootstrap and distribution mechanism, including when tasks fail.

Classification results are cached on the server and locally. Client background
polling is limited to four minutes. No playback operation waits for it. A failed
channel recovery submits a deduplicated discovery request; subsequent catalog
polling receives approved results. Legacy direct GitHub list refresh is disabled
and leaves existing cached channels intact. Personal M3U/Xtream subscriptions
remain explicitly user-managed; no personal credentials are sent to the server.

`server_worker.py` owns GitHub repository search, actual recursive tree
enumeration, AI document selection, bounded referenced-document crawling and
exact URL extraction. AI-invented URLs are rejected. New discoveries go into
`discovery_candidates.sqlite3`; default publication is disabled until repository
provenance is approved. Global route tombstones survive rediscovery.

Deploy the worker service and timer. Store the existing OpenAI-compatible
configuration in `/etc/bobtv/ai.json` (root owned, bobtv group, mode 0640):
`baseUrl`, `apiKey`, `model`; optional `repositories` and
`approvedRepositories`. Do not commit this file or expose its fields to clients.
AI endpoints must use HTTPS, including server-local calls. TLS certificate
verification is required; HTTP downgrade and redirects are rejected. The ccnode
public TLS entry is port 49530; calls originating on ccnode use its TLS listener
on port 49531 with the same certificate hostname.
For ccnode-local execution only, `localTls: true` selects the loopback TLS
connection while retaining ccnode SNI and full hostname/certificate validation.
Configured repositories are refreshed every six hours without fixed playlist
path templates. Existing inventory verification and publication timers continue.
Anonymous jobs have bounded input/body/queue sizes, per-origin rate limits and
worker hourly budgets. Failures receive up to three delayed attempts.

## Hardened background execution

Use `bobtv-task@classification.timer` and `bobtv-task@discovery.timer` instead
of the legacy combined `bobtv-server-worker.timer`. The API, catalog verifier,
classification worker and discovery worker remain separate processes. Slow
GitHub discovery cannot occupy the classification worker. Each worker has a
256 MiB memory ceiling, 40% of one CPU quota, low scheduling priority and a
ten-minute execution timeout. The two workers run at most two external jobs
concurrently. No blanket scanning is added to client startup.

SQLite WAL, transactional queue insertion/claiming and per-lane locks prevent
duplicate execution. Heartbeats renew active leases every twenty seconds.
Interrupted jobs resume; the final interrupted attempt becomes a visible failed
job. Retries wait sixty and then one hundred twenty seconds. Classification
results are cached per model and normalized channel identity for seven days;
uncertain results are cached for one hour without assigning a guessed category.
Country decisions require at least 0.95 confidence. Ambiguous names without
reliable disambiguating metadata remain unknown. Cached results from older,
less strict policies are filtered and excluded from the new item cache.

Failed attempts count toward worker budgets. A blocked task kind does not block
other kinds. Shared AI request limits are sixty per hour and five hundred per
rolling day, in addition to the job budgets. Budget deferral preserves the job,
does not consume a failure attempt, and reports its next retry time.

Task results expose attempts, update time, next retry time and a stable error
code. Status exposes aggregate queue counts, queue age and separate lane health.
No prompts, keys, endpoint credentials, channel names or source addresses are
written into worker logs. Logs rotate at 2 MiB with three retained segments per
lane, under `/var/lib/bobtv/server-worker-*.log`.

`bobtv-data-backup.timer` performs daily online backups of all root-level SQLite
databases, verifies each with `quick_check`, and retains the exact published
catalog manifest and hash-verified snapshot. Only a complete backup receives
`verified.json` and an atomic final directory name. Existing backups are never
deleted automatically. Operators must manage retention and off-host copies;
these local backups do not protect against total server loss.

This change removes discovery/AI dependencies from client networks. It does not
proxy video, accelerate the public site, guarantee regional playback or establish
redistribution rights. Server probes cannot establish mainland ISP reachability
or video identity. Mainland network tests and delivery mirrors are separate work.
