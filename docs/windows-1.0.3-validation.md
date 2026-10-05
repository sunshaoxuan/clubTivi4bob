# Windows local validation, 2026-10-06

Host: sunsx-pc. Test build: 1.0.3+84. This does not publish a formal release or
change the production update feed.

## Verified

- Windows release build and focused Flutter regressions for PiP, fullscreen
  navigation, mouse-accessible exit controls, programme timelines, update
  feedback, manifest validation and shared catalogue changes.
- Physical Windows main playback and desktop PiP video/audio, confirmed by the
  user. Returning from PiP and fullscreen guide interaction are checked
  separately as the user completes each step.
- Setup installation and uninstallation in Chinese/Japanese paths, with desktop
  shortcuts both enabled and disabled, start-menu entries and retained choices.
- Unicode DLL loading in ASCII, Chinese, Japanese and mixed-language directories.
- Real production catalogue download on Windows, integrity validation and fresh
  in-memory initialization: 4,109 routes with verification records, including
  classified CCTV channels. No test channels are uploaded to production.
- Isolated HTTP end-to-end catalogue test: two clients exchange classification,
  route-health changes, additions and retirement records without resurrection by
  stale inventory.
- Windows updater helper-lock handling, application-scoped monitor suspension,
  unchanged locked-file copying and changed-file integrity checks.
- Three-startup-failure rollback and successful-start acknowledgement reset.
- Native progress UI: downloading, verifying, backup, installation and failure
  keep launch disabled; completion requires matching executable version and app
  data. A missing executable remains disabled.
- Real repaired network upgrade of the previously failing installation from
  0.9.1+80 to the production 1.0.1+82 archive. Logs confirmed installation and
  crash-monitor resume. The test build was subsequently installed with a retained
  1.0.1+82 backup and acknowledged healthy startup.

## Cause of the two failed upgrades

The crash-monitor loop kept `Tools/procdump64.exe` open after the player exited.
Both updates finished downloading and validating, then failed replacing that
file. The progress UI also enabled the unchanged launch label after failure.

The worker now pauses the app-scoped monitor, avoids overwriting identical files,
verifies copied content and resumes monitoring. The UI rechecks installation
state and executable version both before enabling launch and on click. Repeated
unchanged progress writes are suppressed.

## Remaining verification boundaries

Multi-monitor dragging, other-app fullscreen interaction and a long-duration
playback soak need separate physical checks. The installer and portable-package
fixtures do not establish that every possible stream codec is supported.
