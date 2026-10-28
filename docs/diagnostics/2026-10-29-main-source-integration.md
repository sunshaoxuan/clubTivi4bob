# Main source integration and local Mac validation

Date: 2026-10-29, Asia/Tokyo.

The maintainer requested the latest source, a local Mac build and tests, then
explicitly required all accumulated local source changes to be committed and
pushed to main before any official release is built. This task does not publish
a release, create a tag, deploy a server, or replace an installed application.

## Source preservation and integration

The original checkout was based on `6ada5e3b340f413b5dcdd417979bf68c1e1c323d`.
Its 330 changed or untracked files were preserved in source checkpoint
`8ff24276d11cf34fd2d2c02ab8d5d7edcba66c71`. A separate integration checkout
started at remote main `e53999ff02809e97a69ac3e9ef0e4c9fa5e9610f`.
The original index and working files were not used as a merge scratch area.

135 local file contents already matched main. Conflict review retains main's
1.1.16+111 version, country navigation, regional taxonomy, FFmpeg ABI support,
signature policy and per-installation Mac update-state isolation. Superseded
global-state Mac updater experiments remain recoverable in the checkpoint;
they do not replace the newer installation-isolated protocol.

The integration includes the accumulated channel-first EPG discovery, evidence
review and bounded worker sources, their tests and the timer activation repair.
It also retires Windows updater monitor-restart calls while retaining the newer
download retry helper, inert packaging shim and built-in native crash recorder.
No source integration is counted as a new live EPG mapping or coverage gain.

The retained `third_party/media_kit` investigation is not an active dependency
override. Its independent lockfile and CI dependency bootstrap keep repository
analysis reproducible. The focused worker test imports the investigation helper
directly. Shipping that fork requires a separate runtime integration and device
acceptance decision.

`AGENTS.md` now explicitly requires the exact release source commit to be
present on remote main before building official packages. Local-only commits
and uncommitted working trees cannot be official release inputs.

## Validation

Latest-main baseline: 872 Flutter tests passed, 22 skipped; static analysis had
no errors, 22 warnings and 181 informational findings. An Intel Mac built the
Universal macOS application and passed strict bundle-signature verification.

Merged candidate: 874 Flutter tests passed, 23 skipped, with concurrency two;
static analysis had no errors, 23 warnings and 183 informational findings.
All 1,345 website tests and five download-menu tests passed. One pre-existing
Starlette/httpx deprecation warning remains. Mac update-state regressions passed
installation isolation, legacy migration, state quarantine, independent rollback,
healthy startup, active-install protection and stale-PID retry cases.

The first merged test run retained two website failures: a stale 1.1.15 string
assertion and an input-mutation assumption predating publication normalization.
The assertions now use the declared version and verify the actual published,
decompressed snapshot while ensuring caller data is unchanged. The first full
Flutter run also retained a 35 ms loopback-fixture timeout failure. Fixture-only
deadlines are now 250 ms with a one-second injected fault. Production transport
timeouts and retry policy are unchanged. The final complete reruns passed.

Native checks on this Intel Mac passed 4,000 owned Metal frames, 500 runtime
adapter callbacks, and 20 hardware-requested MPV decode/disposal cycles with
230 observed frames. Native test audio output used the null backend. A separate
test bundle identifier isolated preferences, data and logs; AI, private-favorite
backup and diagnostic uploads were disabled. Initial application startup and
shared-catalog arrival were observed through the actual UI.

The maintainer manually used and closed the first test instance. After the
requested restart, the UI automation transport repeatedly reached its timeout;
the process remained alive and its sampled main thread was in the AppKit event
loop. Complete second-pass menu interaction is not claimed. The Windows legacy
monitor retirement fixture passed under local PowerShell. The separate Windows
file-lock helper fixture requires Windows path semantics and did not pass on
macOS; native Windows/Android device acceptance was not performed in this task.

Raw local evidence is retained in the integration checkout's `local-*.log` files
and the isolated build checkout's `local-qa/` directory. These generated logs,
environments and application bundles are not source-commit inputs.
