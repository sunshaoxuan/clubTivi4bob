# Desktop ordinary-window sizing

Windows and macOS use one normal-window policy at startup and restoration.
The **outer frame**, including native titlebar and all Flutter toolbars, is
limited to 1920x1280 physical pixels. Screen scaling converts that cap into the
window API's logical coordinates. A smaller monitor's work area takes priority,
excluding its menu bar, Dock or taskbar. The minimum also shrinks when the
available space is smaller, preventing contradictory sizing constraints.

Startup requests a modest 1000x650 logical frame and clamps it to these limits.
Windows starts normally instead of automatically maximizing. Native Windows
creation and the macOS nib window also cap the first frame before Flutter paints.
Ordinary minimize/restore, unmaximize, completed resize/move and display-change
events run the same debounced policy. Saved fullscreen and PiP frames are bounded
through the same helper when restored to an ordinary window.

Explicit maximization and native fullscreen are exempt. Nested sizing leases
give fullscreen transitions and PiP exclusive ownership of geometry so a normal
minimum cannot enlarge the compact player. Minimization and maximization are
rechecked after asynchronous display queries and minimum-size changes; a new
fullscreen transition cancels stale pending normal-window resizing. Repeated
identical minimum sizes are not continually applied.

Window-manager and screen-retriever Windows coordinates use different DPI
divisors on mixed-scale monitors. Display work areas are converted into the
current window's coordinate space before selecting the overlapping or nearest
display. Off-screen saved positions are repaired; negative monitor coordinates
are retained when that monitor is still connected.

## Validation, 2026-10-12

70 focused geometry, sizing, fullscreen and PiP tests passed. Coverage includes
1080p/4K, 100/125/150/200/300 percent scaling, mixed Windows monitor DPI, tiny
work areas, removed monitors, both platform restoration backends, native-event
recovery, nested leases and asynchronous transition cancellation. Static
analysis found no issues in the changed Dart implementation. The macOS native
source passed Swift parsing. The complete Flutter suite passed 428 tests with
8 skips, including the isolated cross-device HTTP synchronization test.

The installed applications were not replaced or restarted. Native package
compilation and installed-application visual acceptance are pending the next
test build. No release or automatic-update feed was changed by this task.
