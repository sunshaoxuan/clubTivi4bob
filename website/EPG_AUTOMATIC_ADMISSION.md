# Server EPG automatic admission policy

The existing source-discovery timer performs the admission check during a
bounded candidate probe. The schedule timer imports only the validated private
cache, and the publisher verifies both public nodes before activation. No local
chat or client release is involved.

Version 1 accepts first-party HTTPS XMLTV only. An unambiguous HTTP Link
relation must declare CC0 1.0 on the actual, unredirected programme response.
The XMLTV channel's exact display name and only URL must identify the
catalogue stream. The stream, feed and fresh identity witness must share one
HTTPS origin. The checked identity witness must link the exact stream hash.
The selected channel needs exactly one current slot and at least one future
slot after normalization. All other candidates retain the existing review
path. An AI assertion, code licence, public webpage, same name or plausible
playback never qualifies on its own.

Admission uses one transaction for a new, locked exact-route mapping and data
grant. Existing approvals (including revoked ones), existing grants, manual
mappings and caches are never replaced by admission. Subsequent refreshes
recheck the feed's licence and channel-to-route declaration. A changed proof
blocks future publication for that mapping and preserves last-good private
rows; a later network failure cannot clear the proof failure. No new provider
quota or discovery timer is introduced.
