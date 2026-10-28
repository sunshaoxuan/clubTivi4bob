# Video handoff and UI responsiveness investigation

Status: unreleased native-cleanup fix, affected-device acceptance pending.

The user reports that a prepared channel's audio switches immediately while the
main picture retains a frozen old-channel image. Other UI interactions freeze
at the same time. This observation narrows investigation to application or
render-thread blocking; it does not establish a particular native root cause.

## Confirmed implementation issue

The Windows release build resolves `media_kit` to pub.dev 1.2.6. Its
`NativePlayer.dispose` tears down streams, renderers and callbacks, then schedules
a synchronous `mpv_terminate_destroy` on the caller's isolate five seconds later.
The [libmpv API contract](https://github.com/mpv-player/mpv/blob/master/include/mpv/client.h)
explicitly documents that this operation blocks until termination. An unawaited
future or a Dart timeout cannot interrupt that synchronous call.

The local patch vendors that exact dependency, preserves teardown order and the
existing grace period, and runs only the final detached-handle termination in a
worker isolate. The disposal future now includes termination, so BobTV's existing
resource registry does not count an unfinished core as released. No active
decoder, route, channel identity, catalogue mapping or EPG logic is modified.
There is no new wait in preview promotion.

Final native termination also runs outside the dependency's static global
player lock. An earlier worker candidate kept that lock during the grace period:
visible handoff was fast and the UI heartbeat gap was 30 ms, but consecutive
previews took about 6.8 seconds. That candidate was rejected. The final revision
releases the global lock immediately after detaching the old core.

This fixes a confirmed blocking path. The affected user's network/device failure
has not been reproduced, so the patch alone is not proof of complete resolution.

## Evidence and verification scope

Evidence directory: `outputs/BobTV-video-handoff-20261017/` in the workspace.

- The frozen production-source Windows baseline displayed six alternating local
  red/green fixtures using the same decoder and controller during each transfer.
  Actual own-window pixel changes took 14,748 to 32,182 microseconds. These are
  local, uncompressed, silent fixtures, not public-channel latency measurements.
- The initial WinRM-session attempt lacked a working graphics context. A later
  idle fixture also did not schedule the post-frame controller initialization.
  Those failed attempts are preserved. The passing run used an interactive user
  session, unique bundle path, checked AOT hash and the production-style loading
  indicator. It did not replace or stop an installed application.
- A test-only C function blocks for 750 milliseconds. A shared native state flag
  proves caller-isolate timer callbacks execute during that call. The test also
  verifies that the disposal future waits for native completion after the
  retained grace period. Source-order and existing resource/preview tests pass.
- The first parallel full-suite run had 723 passing tests, 17 skipped, and one
  failure in the new timing-only responsiveness assertion. That assertion sampled
  overall scheduler latency during compilation. It was replaced by the stronger
  in-call state observation above; focused rerun passed. The complete rerun
  passed with 724 tests and 17 explicit skips before the global-lock refinement.
  A complete final-revision rerun is in `flutter-tests-r2.log`. Static analysis of the changed
  helper, regression test and presentation probe found no issues.
- The final global-lock revision passed the full client suite again: 724 passed,
  17 skipped. Its Windows x64 release fixture passed six actual-pixel transfers,
  with visible changes between 15,157 and 30,889 microseconds. Inter-preview
  intervals were 2.006 to 2.047 seconds, including local preparation and the
  fixture's deliberate observation pauses; the extra five-second lock wait was
  absent. The UI-isolate heartbeat's largest gap was 34 ms, including cleanup.
  Final native resources were zero, exit code was zero, and the installed app's
  process ID was identical before and after. Its one-off task was removed after
  completion. See `interactive-fixed-r2-status.json` and `acceptance-final.json`.
- The patched macOS x64 debug fixture completed three preview creation/disposal
  cycles, ten seconds of two-decoder playback with ten advancing video/audio
  samples, a same-decoder/controller preview promotion, and explicit exit.
  The process exited zero after the resource registry reached zero with native
  termination included. This used a local silent fixture; physical image-change
  latency and audible continuity were not measured. Installed apps were untouched.
  The final global-lock revision repeated this full native test successfully
  (`macos-fixed-validation-r2.json`), including a 9,021-microsecond internal
  ownership transfer. This value measures service handoff only, not visible pixels.

No current-user installed app was restarted. No new release, installer or update
feed containing this patch has been published. Windows ARM64, Apple Silicon,
Android, affected-device network switching and audible continuity remain outside
the current acceptance evidence.
