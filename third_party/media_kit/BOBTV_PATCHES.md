# BobTV media_kit patch

Baseline: the unmodified pub.dev `media_kit` 1.2.6 package, including its MIT
license. The fork does not add a new runtime library or a second player core.

`NativePlayer.dispose` previously scheduled a synchronous
`mpv_terminate_destroy` on its caller's isolate after five seconds. This C API
blocks until player/client termination. Calling `dispose` without awaiting it,
or adding a Dart timeout, cannot prevent that native call from blocking Flutter.

The patch retains the original callback/render-context teardown order and the
five-second event-loop grace period. Final termination runs in a worker isolate
with only the detached handle address and library path. The returned disposal
future now includes actual core termination, allowing BobTV's existing resource
registry and exit barrier to account for unfinished cleanup. The active player
is untouched. Preview promotion does not await this cleanup.

The existing dependency-wide player lock protects only detachment. It is released
before the grace period and worker call, so one old core cannot delay the next
channel's initialization or controls. A real repeated-preview regression caught
and rejected an earlier candidate that held this lock for the full cleanup.

Reference: https://github.com/mpv-player/mpv/blob/master/include/mpv/client.h
(`mpv_terminate_destroy` documents blocking and exclusive context ownership).

This removes a confirmed UI-blocking path. It does not establish that this path
caused every reported video delay, nor replace affected-device playback QA.
