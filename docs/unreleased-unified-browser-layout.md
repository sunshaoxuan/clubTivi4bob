# Unified responsive channel browser

Status: included in the `1.1.4+97` release source. An authorized local Mac test
build has been installed; publication does not restart installed clients.

Windows x64/ARM64, macOS Intel/Apple Silicon and Android now always use the same
balanced channel-browser layout. The old wide-window category Wrap and country
list, old category picker and its controllers are removed. Large displays no
longer switch back to a navigation layout that can consume the preview viewport.

- Equal-width player / channel panes from 640 logical pixels; vertical layout
  below that width.
- At most three single-line category levels, with a complete overflow menu
  anchored to its More button and selected categories kept visible.
- Available viewport and safe-area height determine denser controls, cards and
  programme guides. Original video aspect ratio is preserved.
- Category width measurement inherits the actual text style, and rendered
  button widths use the same budget. Long rows cannot accumulate text-spacing
  errors and push their More button offscreen.
- Preview selection and its EPG stay attached to channel IDs during resize.

The advanced workflow and its functions remain available in the toolbar's More
menu. This change removes the previous layout variants of the simple browser.
Fullscreen playback and platform-native PiP are unchanged.

Validation covers the shared rendered components under all three platform
themes, low / boundary / 4K dimensions, display scaling, system padding, live
resize, every classification menu level, larger text, settings and fullscreen
programme overlays. Native Surface ARM64 and Xiaomi Pad playback still require
physical devices; these widget checks do not stand in for decoder validation.

2026-10-14 validation results: 118 targeted layout/settings/fullscreen checks
passed, with two opt-in visual checks skipped in the regular run. The full
Flutter suite passed 594 checks, with 11 environment/opt-in skips. The visual
check was then run explicitly and generated 36 screenshots across three
platform themes and six viewport sizes. macOS 1290x747, Windows 1366x768 and
Android 800x480 rendered views were inspected: classification stays within three
rows and the first channel card plus its connected EPG are visible. Source
analysis has no compilation errors; pre-existing channels-screen lint findings
remain. The earlier layout-only run did not restart installed apps or alter
1.1.3 assets. Subsequent Mac installation and fullscreen acceptance are recorded
in [the fullscreen notes](unreleased-fullscreen-escape.md).
