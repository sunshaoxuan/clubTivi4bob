# Window and video fullscreen state, 2026-10-15

This repair is included in release 1.1.5+98. Installed applications are not
replaced or restarted by publication. It supersedes the video-return behavior described
in `unreleased-fullscreen-escape.md` for release 1.1.4.

## Interaction contract

Window presentation and video presentation have separate owners. Native window
maximize/fullscreen actions keep the channel page mounted. Opening video
fullscreen captures the caller's window placement and leaves the caller route
and playback service mounted underneath the player route.

| Caller window | Return from video by double-click or Return |
| --- | --- |
| Ordinary | Original bounded placement and normal titlebar |
| Maximized | Original maximized window and normal titlebar |
| Native fullscreen | Original native-fullscreen channel page |

Cocoa-initiated native exits and the Windows window-restore control explicitly
leave native fullscreen as well. Application-handled Escape uses the caller's
saved window state, just like double-click and Return. The owning video route
returns through the same navigation cleanup. Repeated input and disposal share
the same exit operation.

PiP temporarily leaves fullscreen, retaining the original caller snapshot for
the later return. A failed fullscreen entry restores the caller instead of
leaving an unusable full-player route behind.

## Windows caption repair

The window-manager plugin hides the nonclient titlebar layout but keeps
`WS_CAPTION` and `WS_SYSMENU` while fullscreen. The application runner now
suppresses those actual style flags during video fullscreen and restores the
saved flags afterward. This prevents the native caption surface from covering
the application's top-edge controls. Resize and maximize capabilities are
restored with the ordinary titlebar.

The global restore control first asks the active video owner to return, covering
placements where Windows omits a leave-fullscreen event. Its hover dismissal
also allows a short pointer transition toward the buttons.

## Validation

- 66 focused session, platform-channel, navigation, PiP and mouse-control tests
  passed, including ordinary/maximized caller restoration, native fullscreen
  callers, external exits, in-flight cancellation and PiP return snapshots.
- The complete Flutter suite passed 613 tests, with 11 environment/opt-in skips.
- Windows native fixture: ordinary and maximized callers each passed three
  fullscreen/return cycles. Original rectangles matched within two physical
  pixels. Fullscreen caption inset was zero; both native caption style flags
  were absent. Normal return restored a 31-pixel caption inset, resize/maximize
  capability and the original zoom state. Native-fullscreen caller re-entry and
  PiP restoration also passed.
- The optional `--capture` native-control screenshot attempt did not acquire
  the foreground window and stopped at its ownership guard. No other window
  was captured. Pixel-level acceptance of the reported white strip remains
  pending; native style and geometry checks are separate from visual acceptance.
- Android debug APK and the Mac application compiled successfully.
- Initial Mac testing was blocked by its locked desktop. An invalid superclass
  termination callback found during that test was removed. The unlocked native
  acceptance on 2026-10-16 passed, as recorded below.
- No Android hardware is connected. Mobile system-UI ordering is covered by
  regression tests, with tablet acceptance still pending.

The Windows fixture uses a separate source/build directory, leaves the installed
BobTV process running, and skips production updater/crash-monitor state. It does
not validate stream playback. The Mac fixture likewise starts no catalogue,
player or Dart update services.

Fixtures: `tools/windows/fullscreen_validation.dart` and
`tools/macos/fullscreen_return_validation.dart`. All native Mac tests require an
unlocked interactive desktop. The focused suite is:

```sh
flutter test --no-pub test/desktop_fullscreen_session_test.dart \
  test/window_manager_fullscreen_backend_test.dart \
  test/windows_fullscreen_controls_test.dart \
  test/window_manager_pip_backend_test.dart \
  test/fullscreen_return_navigation_test.dart \
  test/mobile_fullscreen_session_test.dart
```

## Unlocked Mac acceptance, 2026-10-16

The isolated Flutter fixture used the actual Cocoa window and production
fullscreen session/backend. All 13 recorded scenarios passed:

- Ordinary caller, video entry and double-click return: three cycles restoring
  the original 1000 x 650 placement.
- Maximized caller: three cycles preserving the original 2048 x 1172 frame and
  native zoom state.
- Native-fullscreen caller: three cycles returning to the original fullscreen
  channel layout at 2048 x 1280.
- Cocoa native exit returning the owning video route to its caller.
- An actual Quartz Escape key event sent only to the fixture's own PID. Flutter
  received the key and restored the ordinary caller.
- Two additional fullscreen/double-click return cycles after Escape, preserving
  the caller window geometry and the same mounted channel state.

The first unlocked run passed the six ordinary/maximized cycles, then timed out
waiting for a double-click return from an already-fullscreen caller. That input
was sent before the Material route's 300ms transition completed. The fixture now
waits for route presentation before sending input, including when native entry
requires no animation. The repeated run passed all 13 scenarios without any
further production-code change. Its process exited with code zero and no
Objective-C termination exception.

Evidence: `fullscreen-macos-report-20261016-unlocked-2.json` and
`fullscreen-macos-run-20261016-unlocked-2.log` in the workspace outputs directory.
This checks actual native window/route/input behavior, not live stream decoding
or sound quality. No installed application was replaced, restarted or published.
