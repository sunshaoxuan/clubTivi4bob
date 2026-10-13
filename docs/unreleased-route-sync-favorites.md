# Channel-state and favorite fix notes

These client changes are included in `1.1.4+97`, after the immutable `v1.1.3`
package source. Publication does not replace or restart installed clients.

- Selected channels request fresh permanent retirement state for their
  candidates before playback. Current-category metadata is queued in small
  batches; foreground requests have priority. Native decoder entry points
  also check fresh state. Failed foreground sync keeps the old programme and
  shows a retry message, without trying an unconfirmed public route.
- The additive live-state API is deployed to the primary server. Both the
  primary and cndrp paths returned the recently retired CCTV-6 address with
  no-store headers; cndrp explicitly reported BYPASS. The retirement is
  already durable locally and in the public inventory.
- Endpoint identity includes path and query parameters. Two addresses on
  the same host can carry the same contaminated video while remaining
  distinct endpoints. A host-wide ban is not inferred from one retirement.
- Favorites now include equivalent channel routes across providers and
  classifications. CCTV-5, CCTV-5+, UHD variants and radio remain distinct.
  Old one-route favorites expand on first use; new imported routes inherit
  existing membership; removal applies to the entire service. Retirement
  removes the bad endpoint from all lists without restoring it on import.
- Favorite snapshots continue to contain only device-private hashed route
  references. Public catalog APIs never receive a user's favorite selections.
- A regional-ranking future cleanup no longer returns its own pending
  future, preventing a request from waiting for itself after completion.

Client synchronization and favorites are covered by automated and real-HTTP
tests. Fullscreen acceptance was separately performed on the authorized local
Intel Mac test build. Physical Windows and Android acceptance remains pending.
