# Desktop picture in picture

The existing player toolbar button enters a compact, always-on-top desktop
window on Windows and macOS. BobTV uses its existing native window, Flutter
engine, active media player and video controller. The channel browser is tucked
away rather than running a second visible main window. No second media decoder
or playback URL is opened for this transition.

The default location is the current monitor's usable bottom-right corner.
Dragging the video or header moves the window, including between monitors.
Native window edges allow resizing. Saved bounds are clamped to an attached
monitor, with a current-monitor fallback after display disconnection.

The compact controls provide volume, mute, expand, return to channels, and exit
BobTV. Expand and video double-click restore fullscreen playback. Return restores
the original window presentation and returns to the channel browser while
retaining fullscreen, consistent with the existing fullscreen return behavior.
The close icon explicitly exits BobTV; it does not leave hidden audio running.

macOS enables visibility across Spaces for compact mode and restores the prior
workspace setting on return. Fullscreen transitions still use native completion
acknowledgements. Display-specific and other-app fullscreen Space behavior needs
physical testing; Windows physical testing is pending its build host being online.

This is an application-managed compact-window implementation. Minimizing the
compact window itself hides it; there is no separate main window to minimize.
The normal channel UI, controls and minimum dimensions return after leaving it.

Version 1.0.3 build 84 is currently a local test build, not a formal release.
