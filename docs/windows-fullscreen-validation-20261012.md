# Windows fullscreen regression, 2026-10-12

## Correction

Windows fullscreen entry now explicitly hides the native titlebar before the
window manager changes geometry. Ordinary window restoration uses one shared
helper to restore the titlebar, resize capability and maximize capability.
Re-entry from a fullscreen channel page does not save the temporary disabled
maximize style as the normal-window preference.

Windows completion is checked against the native fullscreen flag. The
mouse-accessible window controls also refresh state on resize and focus because
the plugin can omit its enter/leave notification for some placements. The macOS
transition and titlebar paths remain unchanged.

## Automated verification

- 55 fullscreen, native-window-control, navigation and picture-in-picture tests
  passed.
- Static analysis of the 9 changed Dart implementation, fixture and test files
  reported no issues.
- `git diff --check` passed.

## Native Windows verification

An isolated fixture was built with the known Windows Flutter SDK and run in the
interactive `sunsx` desktop session on SUNSX-PC. It uses the actual
`window_manager` plugin and the corrected application backends, without starting
the player, catalogue, or the Dart updater. The application installation was not
replaced.

| Starting state and path | Result |
| --- | --- |
| Ordinary window, fullscreen and return, 3 cycles | Passed |
| Maximized window, fullscreen and return, 3 cycles | Passed |
| Return to channels while keeping native fullscreen, re-enter, restore | Passed |
| Compact picture-in-picture window and restore | Passed |

For every fullscreen cycle, native `GetWindowRect`, `GetClientRect` and
`ClientToScreen` measurements showed an outer frame and client area of
3840 × 2160, with zero caption inset. After normal restoration, the caption inset
was 31 pixels, native maximize capability was enabled, and both maximize and
restore commands succeeded. The original ordinary or maximized state was
retained. The fixture result was `passed: true`, 8 records, `error: null`.

The fixture exited on completion. Its report remains at
`C:\Users\sunsx\src\BobTV-window-qa-20261012\window-report.json`.
The one-off scheduled task was removed. The baseline native runner's shutdown
callback produced a zero-byte updater health marker at fixture exit; that exact
marker was moved to `isolated-native-health-marker.backup` in the QA directory,
so this geometry test cannot validate the installed update candidate. The
preparation script now also disables that shutdown callback for subsequent QA
builds.
This verifies native geometry and state transitions. A visual test of the full
production player with mouse double-clicks was not performed, and no application
release or installation was made during this validation.
