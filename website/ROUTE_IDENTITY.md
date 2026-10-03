# Public route identity

Each HTTP media endpoint has one global identity, independent of the reporting
device, repository, provider name, channel label, or category. Scheme and host
case are normalized, default ports are removed, and an empty path becomes `/`.
Path spelling, query parameters, HTTP versus HTTPS, and non-default ports remain
distinct. No URL parameters are discarded and channel names alone never establish
route identity.

The inventory enforces unique canonical URLs and retains multiple provenance
records separately. Legacy equivalent URLs are merged transactionally once;
blocked/deleted flags survive, manual classifications take precedence, and health
votes are retained. Retirement is monotonic and repeated retirements do not
increment the revision again. Re-importing a retired endpoint cannot reactivate
it. Published snapshots reject duplicate endpoints, even with different route IDs.
