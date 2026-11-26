# Windows to Mac AirPlay authentication development validation

Status: development source and isolated QA packaging. Physical acceptance is
pending. No official desktop release has been built or published from this work.

## Implemented behavior

- Native Mac pairing offers an explicit screen PIN or receiver password choice,
  including when the receiver's advertisement omits its password requirement.
- PIN uses HAP M1 through M6, verifies the SRP server proof and signed receiver
  identity, and saves credentials only after all checks pass. Saved credentials
  use checked pair verification through PV4 on subsequent control connections.
- Password uses full HKP 3 / HAP M1-M6 with the configured secret, checked server
  proof and receiver identity. Its derived credential stays only in helper
  memory for Pair-Verify on fresh connections. The password is discarded after
  setup; neither it nor its temporary identity is written to pairings or logs.
  Complete physical acceptance remains pending.
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
- Native Python suite: 67 passed on both Mac and SUNSX-PC with complete QA
  FFmpeg. Source 8b989dfdb0d7e1aee0026c4d89f90a7bc709c59c was frozen on Windows
  and passed packaged startup checks. Successful and rejected SRP exchanges are simulated
  cryptographically; these are not physical receiver tests.
- Diagnostic server validation and relay tests: 12 passed.
- Targeted Flutter analysis: no errors or warnings; informational style lints.

FFmpeg stderr is classified into fixed diagnostic events for missing encoders,
decoders, filters or protocols, HTTP rejection, route and connection errors,
resource exhaustion, unsupported options and invalid media. Classification spans
read boundaries and deduplicates repeated causes; no raw stderr enters upload.

The first Windows CI regression run exposed an unpinned SRP dependency:
Python 3.12 selected srptools 2.0, whose constructor API differs from the API
used by pyatv 0.18.0. requirements.txt now pins the locally tested 1.0.1 version.
Windows drive-qualified recording paths are also explicitly recognized before
URL parsing. Windows CI run 45872465371 passed all regression, compilation and
frozen-helper checks at source 2472c37812edf7d5d5a97fbeece66308fabefb88.

## Physical authentication finding

At 08:02 JST, the isolated Windows helper reached the physical Mac and received
HTTP 470 at M2 for the original transient password implementation. No password
proof or media transmission had occurred. The same Windows host then probed
M1 with a client name: HKP 4 again returned 470; HKP 3 returned HTTP 200 with a
409-byte TLV M2 challenge (state 2, salt and public key). This establishes the
need to complete full HAP for this password policy. It does not establish that
the subsequent password proof or video playback succeeds.

The rebuilt Windows helper returned the successful password-mode M2 from the
physical receiver, and that preflight was explicitly cancelled without sending
a secret. Its network probe completed with source 192.168.11.5, target
192.168.11.8, prefix 24, interface index 12 and `sameSubnet: true`.

An independent Flutter QA harness then imported the actual failed attempt and
its timestamped Windows system sample into the production DiagnosticLogStore
and DiagnosticSyncService. The normal uploader sent four safe records through
cndrp, retained its pending outbox until `origin_accepted`, and committed the
cursor. Auth mode, M2, HTTP 470, code locations and CPU/RAM fields survived a
private origin download with a verified content hash. This tests the production
upload module; it is explicitly not labeled as installed-application automatic
collection. The batch digest is
`d4176c18bf8e6176d234da05dc3de2f35e5708148fa1277e554169b206053fd5`.

Network diagnostic collection now records its duration and probe failures,
including PowerShell timeouts, instead of silently dropping the probe cause.

## Remaining acceptance

- Complete password proof, identity verification and physical media playback
  using the rebuilt Windows helper. M2 success alone is insufficient.
- Verify the application UI using the same helper. Current physical collection
  uses an isolated native helper and is explicitly marked as manual QA capture.
- Verify screen PIN, wrong PIN, receiver password, wrong password, cancellation,
  backoff and saved PIN credential reconnection against the physical Mac.
- Confirm decoded video at the receiver and collect automatically uploaded
  incidents, including the following operation window, from the origin.

The minimal LGPL Mac relay FFmpeg added here supports remuxing and AAC. It does
not supply the libx264 encoder required by the separate native Mac frame sender.
The isolated Windows QA archive includes a full FFmpeg binary for that sender.
Mac native-sender encoding remains a separate packaging acceptance item.
