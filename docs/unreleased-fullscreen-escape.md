# Fullscreen Escape and re-entry

Included in the `1.1.4+97` release source, following 1.1.3. The earlier
local repair and acceptance did not change public release assets.
A local Mac test build was installed with the user's approval on 2026-10-14.
Windows and Android installed applications remain unchanged by this repair.

## Evidence and cause

The installed Mac log recorded repeated `fullscreen_enter` failures with
`Native fullscreen state did not reach true`. A pending return to channels
waited on this entry and therefore inherited its ten-second timeout.

The old Mac backend raised an ordinary NSWindow to `.floating` after entering
its native fullscreen Space. Returning to channels transferred fullscreen but
retained that level after the player's owner was disposed. Native window exits
on the channel page did not have an active player owner to repair it.

An isolated Cocoa test, using the automatic fullscreen collection behavior of
BobTV's MainMenu.xib, reproduced a native fullscreen exit timeout with the old
floating level. The same test, changing only the fullscreen window level to
normal, passed four complete native enter/exit cycles. An explicitly primary
fullscreen test window can behave differently; this is a repair of BobTV's
actual automatic-window configuration, not a claim about all Cocoa windows.

## Repair

- Mac entry and exit normalize the native window level before a transition.
  Fullscreen no longer raises the Mac window to the floating/PiP level. Windows
  retains its existing fullscreen always-on-top behavior.
- Native exits from an active player restore the saved normal-window state.
  The Return and double-click actions still return to the channel page while
  preserving a fullscreen window, matching the existing interaction contract.
- Native Escape during entry cancels the pending transition immediately.
  Cancellation before the method acknowledgement is observed safely and cannot
  publish a stale fullscreen state or keep return navigation waiting ten seconds.
- Android/mobile immersive mode has one route-owned session. Back waits for
  entry/restore ordering, duplicate cleanup is coalesced, restoration can retry,
  and the next route cannot inherit a late system-bar restoration from the old
  route.

## Validation

`test/window_manager_fullscreen_backend_test.dart` covers stale floating state,
four player/channel/native-exit/re-entry cycles, active-player native exit,
Escape during entry, cancellation before native acknowledgement and Windows
ordinary/maximized placements, chrome, resizability, maximization and topmost
state. The shared session, return-navigation, PiP and window-sizing tests cover
duplicate exits, rapid transitions, route cleanup, popup cleanup and minimized
windows.

`test/mobile_fullscreen_session_test.dart` covers eight Android enter/back cycles,
Back during entry, failed entry, retryable restoration and actual SystemChrome
method-channel ordering. Android exit and PiP coverage remains in the suite.

Run the isolated Mac native test with:

```sh
xcrun swiftc tools/macos/test_fullscreen_cycle.swift -o /tmp/bobtv-fullscreen-cycle-test
/tmp/bobtv-fullscreen-cycle-test
```

The optional `--legacy` run is expected to fail on the affected automatic-window
configuration. It creates a separate temporary test window, changes no installed
BobTV app/data and closes its own process after completion.

Physical Windows and Android tablet playback are not verified by mocked
platform-channel tests. These platforms still require installed-app acceptance.

2026-10-14 results: 49 focused session/platform tests passed. The complete Flutter
regression suite passed 606 tests, with 11 environment/opt-in skips. The Mac app
compiled successfully with both x86_64 and arm64 slices in the executable and
Dart App framework. The isolated native legacy run timed out leaving fullscreen;
the normal-level repair passed four complete enter/leave/re-entry cycles.

## Installed Mac acceptance, 2026-10-14

The compiled test app is installed at `/Users/shou/Applications/BobTV.app`.
Its existing application data was preserved. The previous app was moved to
`/Users/shou/Applications/BobTV-test-backup-20261014.7KZRbn/BobTV.app` for recovery.
The installed AirPlay and update-progress helpers were retained, and the new app
passed `codesign --verify --deep --strict` after ad-hoc signing.

Acceptance used `tools/macos/bobtv_ui_probe.swift`, restricted to the exact
installed BobTV bundle path and verified PID. It checks foreground ownership
and window bounds before sending input. Screenshots capture only owned BobTV
windows. Pointer movement is sent before button clicks so auto-hidden controls
are visible for hit testing. Native Space animations are allowed to settle
before reading the final state.

- Double-clicking video entered true native fullscreen, confirmed independently
  by `AXFullScreen=true`, 2048 x 1280 bounds and normal native window level 0.
- Escape returned to channels while retaining the fullscreen channel window;
  another Escape on channels exited native fullscreen. Re-entry by double-click
  then completed in about 0.76 seconds, without the old ten-second timeout.
- Double-clicking the full player returned to channels in about 2 milliseconds
  of application transition processing. This timing excludes event delivery,
  animations and screenshot collection.
- After another native Escape, the channel-page fullscreen button entered true
  fullscreen in about 0.74 seconds. Moving the pointer to reveal the controls
  and clicking the top Return button restored channels in about 35 milliseconds
  of application transition processing.
- The same app process remained alive throughout acceptance and video continued
  across the transitions. The final native window was not fullscreen, measured
  1374 x 877 at (438, 199), and displayed the CCTV-10 channel list and video.
- No new `Native fullscreen state did not reach true` timeout occurred in this
  installed test session. Existing decoder/network messages are not treated as
  fullscreen failures or as proof of flawless long-term playback.

The local downloadable test app also includes the retained AirPlay and updater
helpers. The app executable and Dart framework contain x86_64 and arm64 slices,
but retained helper components include x86_64-only binaries. This local Intel
Mac test package is not an Apple Silicon release-validation claim. No GitHub or
website release was published as part of this acceptance.
