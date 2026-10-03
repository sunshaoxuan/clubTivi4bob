# BobTV owned Metal frames

This adapter is macOS-only. It does not change Windows, iOS, audio decoding,
hardware-decoder selection, or channel failover policy.

The October 3, 2026 crash occurred on Flutter's raster thread in
`wrapRGBATexture:aiksContext:` while retaining the supplied Metal texture.
Flutter's RGBA external-texture callback released its `CVMetalTexture` before
the subsequent wrapper retained the borrowed `MTLTexture`.

Upstream evidence:

* https://github.com/flutter/flutter/issues/157379
* Apple's `CVMetalTextureCacheCreateTextureFromImage` documentation requires
  retaining the CV texture until GPU use has finished.

`OwnedMetalFrame.mm` replaces the matching RGBA callback only for this plugin's
`SafeResizableTexture`. It verifies the method, ivars, and the 56-byte external
texture ABI before installing. An incompatible runtime is refused and logged.

Each callback creates a distinct, zero-copy Metal texture view. An associated
owner retains the CV texture and pixel buffer. The original CV-owned Metal
texture has no associated owner, avoiding an ownership cycle. A per-callback
frame holder keeps the view and pointer array alive until Flutter retains the
view. Engine and GPU ownership then retain the backing for the view's lifetime,
including after the video output is unregistered or resized. Resource release
does not use arbitrary timers, frame-count retention, or unbounded queues.

Validation:

```sh
bash tools/macos/test_owned_metal_frame.sh /path/to/BobTV.app
FLUTTER_ROOT=/path/to/flutter BOBTV_TEST_LIVE_FRAMES=1 \
  bash tools/macos/test_native_video_disposal.sh /path/to/BobTV.app
FLUTTER_ROOT=/path/to/flutter BOBTV_TEST_LIVE_FRAMES=1 BOBTV_TEST_HARDWARE=1 \
  bash tools/macos/test_native_video_disposal.sh /path/to/BobTV.app
```

The owned-frame test exercises the actual bundled Flutter method 500 times,
then verifies 4,000 frames across two streams with resizing, cache flushing,
producer disposal before GPU execution, GPU readback, and zero retained
backings after completion. The native-output test generates its own raw-video
fixture and consumes frames before repeatedly destroying MPV with textures
still retained by the mock renderer. CI must exercise the bundled engine on
every release, as this compatibility adapter depends on a private engine ABI.

These stress checks cover ownership transitions. They do not establish that
every signal format or long-running real-world playback session is crash-free.
