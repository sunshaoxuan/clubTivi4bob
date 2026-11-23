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

## Verified updater handoff (unreleased)

The player starts its bundled bootstrap worker. After downloading the target
app, the worker verifies archive size, SHA-256, publisher signature, bundle
signature, version, architecture and any installed publisher requirement.
Targets carrying `assets/updater/mac-updater-handoff-v1` supply a compatible
replacement worker. The bootstrap copies that verified script outside Stage and
executes it under the existing installation lock. Its successor reuses the
downloaded archive and independently verifies it before proceeding.

The successor prepares the target's native progress app before installation.
The new observer claims only its requested update run; the previous observer
retires itself without signalling the player or installation worker. A late old
observer cannot reclaim that run. Observer launch failure leaves the current
observer available. Each built observer records the enclosing app's public
version and native build number in its bundle metadata.

The player remains installed and running during this handoff. Its verified
replacement is installed only after exit, using the existing backup, startup
confirmation and rollback flow. No separate unsigned component or extra package
download is introduced. Legacy targets without the marker keep the existing
installation path. An already installed client needs the release containing this
bootstrap before it can perform handoffs on subsequent updates.

Additional checks:

- `bash tools/macos/test_updater_handoff.sh` exercises real signed fixture
  archives, worker replacement while the player PID remains alive, inherited
  installation locking, a single download, retained backup and signature failure.
- Compile `tools/macos/update_progress.swift`, then pass the binary to
  `python3 tools/macos/test_updater_observer_handoff.py PATH`. It checks real
  observer processes, replacement, late old observers and unrelated update runs
  with a live fixture player PID and no visible windows.
