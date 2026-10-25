# macOS distribution profiles

BobTV's packaging checks distinguish Apple Developer ID signing from the project's
separate update-archive signature. Both profiles verify the complete app bundle
with `codesign --verify --deep --strict` and require BobTV's bundle and signing
identifier, `com.briconbric.bobtv`.

- `BOBTV_MAC_DISTRIBUTION=developer-id` is the default. It additionally requires a
  valid Apple Developer ID Application signature. Ad-hoc apps are rejected.
- `BOBTV_MAC_DISTRIBUTION=self-hosted` is an explicit release choice for BobTV's own
  website. It accepts a structurally valid ad-hoc app. It does not imply Apple
  Developer ID identity, notarization, or Gatekeeper trust.

For the 1.1.11 release, the maintainer explicitly selected the self-hosted profile
on 2026-10-25 because a Developer ID certificate is unavailable. Both Mac
architectures use the same application source. Website DMGs and automatic-update
ZIPs retain this documented signing limitation.

`BOBTV_CODESIGN_IDENTITY` selects the available code-signing identity when preparing
architecture-specific app bundles; omitting it uses an ad-hoc signature. Setting a
self-hosted distribution profile does not alter the signing identity or weaken an
installed app's update identity check.

Every automatic-update ZIP still requires BobTV's existing publisher signing key,
a matching public-key verification, SHA-256 and size validation, and the updater's
bundle, version, architecture and path checks. If the currently installed app has
a certificate-backed TeamIdentifier, its replacement must also satisfy its
existing designated requirement before any backup or replacement begins.

Ad-hoc signatures identify a particular binary build. A later ad-hoc build cannot
promise stable Keychain identity continuity. The disabled-feature checks,
non-interactive background access and persisted authorization pause prevent
repeated credential prompts; explicit reauthorization may still be needed after
an upgrade. Existing credentials are preserved.

Notarization runs only when the complete `NOTARY_KEY`, `NOTARY_KEY_ID` and
`NOTARY_ISSUER` configuration is supplied, and requires successful submission and
stapler checks in the packaging script. This release does not claim Apple
notarization. A future Developer ID release must additionally validate its actual
certificate and notarization results before advertising them.

Run `bash tools/macos/test_update_worker.sh` for rollback/locking tests and the
signing-policy regression suite. The signing suite uses isolated, ad-hoc signed
fixtures and real system requirement evaluation. Its synthetic TeamIdentifier
branch exercises worker policy; it does not substitute for a real Developer ID
cross-version acceptance test.
