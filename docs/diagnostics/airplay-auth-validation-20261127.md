# Windows to Mac AirPlay authentication development validation

Status: development source and isolated QA packaging. Physical acceptance is
pending. No official desktop release has been built or published from this work.

## Implemented behavior

- Native Mac pairing offers an explicit screen PIN or receiver password choice,
  including when the receiver's advertisement omits its password requirement.
- PIN uses HAP M1 through M6, verifies the SRP server proof and signed receiver
  identity, and saves credentials only after all checks pass. Saved credentials
  use checked pair verification through PV4 on subsequent control connections.
- Password uses a transient SRP exchange with the supplied secret and checked
  server proof. The password remains in the helper process memory and is passed
  to new control and reverse connections. It is never persisted in pairings or
  diagnostics. Compatibility with the physical Mac's password policy remains
  to be verified.
- Authentication cancellation, explicit receiver errors and retry backoff are
  recorded. Rejected secrets do not fall back to the protocol's transient value.
- Native frame transmission reports `streaming`. A frame counter alone does not
  establish that the receiver rendered video.

## Diagnostic evidence

The application records a session and incident ID, preceding safe breadcrumbs,
the operations within the following window, error classification, filtered code
locations, resource samples and route/subnet probes. Authentication metadata
contains mode, endpoint, phase, HTTP and TLV codes, retry delay and result.
Probe status and age distinguish unavailable or current evidence. Arbitrary
exception text, passwords, PINs, keys and media URLs are excluded from upload.

Queued application events retain their occurrence timestamps and report write
delay. A completed incident wakes automatic upload even when a previous run
reached its local batch limit. Remote and network retry delays remain protected.

The origin and cndrp validation modules were deployed with backups on
2026-11-27 JST. One separately identified manual synthetic schema batch received
`origin_accepted` from both nodes. This validates transport and schema only.

## Local checks

- Flutter casting, authentication UI, diagnostics, updater and catalog regressions:
  78 passed on Mac.
- Native Python suite: 62 run, one FFmpeg-dependent test skipped on the local
  Python environment. Successful and rejected real SRP exchanges are simulated
  cryptographically; these are not physical receiver tests.
- Diagnostic server validation and relay tests: 12 passed.
- Targeted Flutter analysis: no errors or warnings; informational style lints.

## Remaining acceptance

- Obtain an authenticated SUNSX-PC session. WinRM currently responds with HTTP
  401 to an unauthenticated request; an open port does not establish login.
- Run the Windows QA helper and application with the full QA FFmpeg dependency.
- Verify screen PIN, wrong PIN, receiver password, wrong password, cancellation,
  backoff and saved PIN credential reconnection against the physical Mac.
- Confirm decoded video at the receiver and collect automatically uploaded
  incidents, including the following operation window, from the origin.

The minimal LGPL Mac relay FFmpeg added here supports remuxing and AAC. It does
not supply the libx264 encoder required by the separate native Mac frame sender.
The isolated Windows QA archive includes a full FFmpeg binary for that sender.
Mac native-sender encoding remains a separate packaging acceptance item.
