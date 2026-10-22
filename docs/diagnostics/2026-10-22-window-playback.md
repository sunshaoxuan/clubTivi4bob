# Window-filling playback

## Behaviour

- Desktop preview footers now show a window-filling action immediately to the
  left of the existing native fullscreen action. Both simple and compact home
  layouts use the same action widget. Mobile retains its existing action.
- The new action opens the standalone player route with `startFullscreen=false`.
  It fills the application client area, hides the home toolbar and channel grid,
  and leaves native window bounds, maximization and fullscreen state untouched.
  The existing aspect-ratio policy remains `BoxFit.contain`.
- The current channel retains the same player and video controller, including
  paused playback and a currently active failover URL. No media open is needed
  for a presentation-only change. Distinct known channel identities are checked
  separately even if their URLs coincide.
- Back or Escape returns to the original channel page. In window playback,
  fullscreen controls, double-click, F and F11 can enter native fullscreen.
  Leaving that temporary fullscreen returns to the window player. A subsequent
  entry captures fresh native bounds rather than reusing stale geometry.
- Picture-in-picture restoration follows the presentation active before entry.
  The original fullscreen launch remains the default for existing route callers.

## Checks

- New unit tests cover zero native operations during ordinary window playback,
  repeated entry and exit, negative-coordinate/maximized window snapshots,
  native exit, Windows restore controls, in-flight entry cancellation, recovery
  after an entry failure, and disposal during entry.
- New widget tests cover both footer sizes, independent actions, narrow widths,
  and accessibility text scaling. Actual production player routing is exercised
  with an in-memory database and simulated playback: its surface measures the
  full 984 by 611 client viewport, Escape preserves the caller State, and the
  player/controller, play/pause state, position and volume remain unchanged.
- Local playback tests use a silent simulated decoder with volume zero. No
  real stream is opened and no device-wide volume is changed. Future local
  tests using a real decoder must set its volume to zero before opening media.
- The targeted suite includes the existing desktop fullscreen, PiP, navigation,
  native backend, window chrome, tablet and compact-layout regressions.
  Final result: 210 passed, 2 existing environment-gated visual checks skipped.
- A debug Android ARM64 Dart/asset bundle compiled successfully. This is a
  compile check, not a native desktop acceptance test.
- Analysis of the new implementation and test files is clean. Analysis of all
  affected existing files also completed without compile errors; existing
  unused-field, deprecation and style diagnostics remain outside this change.

## Scope

Existing workspace changes, including the radio surface, catalogue identity,
updater and website work, are preserved. No release, website deployment,
installation or operation of the user's running app is part of this change.
Physical Windows/macOS video presentation, native PiP recovery and audible
continuity have not been exercised on an installed app in this task.

## Window pin follow-up

- A push-pin button sits beside the home preview's window/fullscreen controls
  and is also available in the window player's control bar. An outlined pin
  means off; the filled amber pin means on, with matching accessibility state
  and a cancel tooltip. Both views share one application-window preference.
- The preference applies during the current app run until cancelled. No system
  volume, system-wide window setting, startup behaviour or on-disk preference
  was changed. The setter verifies the native result before publishing the UI
  state. Failed writes attempt rollback and leave a visible error message.
- Fullscreen and PiP lock pin changes during their native level transitions,
  wait for an outstanding pin request, and restore the explicit choice when
  returning to windowed mode. macOS fullscreen Spaces keep a non-floating native
  level; native exit or focus can reapply the requested ordinary-window pin.
- At widths below 1000 logical pixels, the control bar omits its supplemental
  EPG/FPS/buffer badges so that the pin and playback actions still fit. The
  programme overlay and information action remain available. The production
  player route is tested at both 984 by 611 and 800 by 500, using HD metadata,
  simulated playing/paused decoders and volume zero.
- Added tests cover shared button state, exact native bridge calls, failure and
  verification rollback, duplicate requests, nested presentation locks, stale
  snapshot restoration, Mac native fullscreen exit and Windows restore chrome.
  Local tests remain silent and do not open real media or operate installed apps.
  Final follow-up result: 230 passed, 2 environment-gated visual checks skipped;
  analysis of the new pin code and affected native backends/tests is clean.
