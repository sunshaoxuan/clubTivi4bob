# Resource relay verification, 2026-10-12

## Deployed state

- `https://cndrp.com/bobtv` relays only fixed-origin BobTV resource/API paths.
- `bobtv-resource-relay.service` is active, separately owned and bounded to
  256 MiB memory and 60% of one CPU. Observed memory was approximately 36 MB.
- Nginx's disk cache is bounded to an 8 GiB target; package and snapshot requests
  transition from MISS to HIT. Mutable metadata and uploads bypass it.
- Canonical origin `bobtv.service`, cndrp Nginx, Postfix and Dovecot were active
  after deployment. The cndrp homepage remained HTTP 200 with its original ETag.
- The relay's direct origin TCP connection uses full TLS verification with
  `bobtv.briconbric.com` SNI. No certificate bypass or HTTP fallback was used.
- Website download/diagnostic scripts and localized template tags were updated
  without replacing existing styles or translations.

## Public checks

`tools/test_live_resource_relay.py` passed on 2026-10-12T04:47:34Z:

- Both 65,536-byte probe bodies and node identifiers were valid.
- Primary and relay catalog manifests were identical. The complete compressed
  snapshot matched its SHA-256 and was subsequently served from cache.
- Client profile `JP:nec2d19168017:4713` remained identical on both paths.
- One synthetic diagnostic submitted through the relay produced a canonical
  receipt. Submitting identical bytes directly returned the same ID and
  `duplicate=true`. No channel or route mutation was used in production tests.
- All seven platform update feeds were identical on the two paths.
- ARM64 Windows ZIP download: 66,829,152 bytes, SHA-256
  `7a0bc655b87881771af8026288f12c7228cc02f4175677fdc108bf2be42db28d`.
  A subsequent Range request returned HTTP 206 from cache with the correct size.
- Media and unrelated admin paths returned HTTP 403 on the relay.
- Browser preflight permitted POST from the canonical website. A cached package
  retained exactly one correct Access-Control-Allow-Origin header.

The actual Dart client transport was exercised with
`tools/test_live_resource_router.dart`. From the current Japanese network it
selected the faster primary, fetched the real feed, preserved its canonical
archive URL and left the video source direct. Fake-network tests separately
verified relay selection, expiration, connect/HTTP failure fallback and prevention
of blind upload replay.

## Tests and delivery limits

- Complete Flutter suite: 393 passed and 9 skipped. The subsequently added
  header-injection check passed with the 16 targeted routing/egress tests.
- Website Python suite: 134 passed, followed by a passing restricted-CORS test.
- Browser-script tests: 7 passed, including unchanged OS/CPU download grouping.
- Network-constructor audit passed. New transport modules had no analyzer errors.
- No new release or client installation was published in this deployment.
  Existing desktop apps were not stopped, replaced or restarted.
- macOS package build could not proceed because this environment has only
  Command Line Tools and no available Xcode `xcodebuild`.
- Android release code compilation completed, but packaging lacked the existing
  release-keystore environment. No replacement signing key was generated.
- Real browser interaction/visual QA and mainland network measurements were not
  performed. Old installed clients require a future signed package to gain the
  new native-client transport. The website transport is already deployed.

Backups: origin trust/code under `/opt/bobtv/backups/resource-relay-*`,
website scripts/tags under `/opt/bobtv/backups/resource-web-*`, and cndrp custom
configuration under `/opt/bobtv-relay/backups/`. Server-only HMAC credentials are
kept in protected configuration files, never repository or release contents.
