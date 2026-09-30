# BobTV macOS render disposal barrier

Based on the MIT-licensed media_kit_video 2.0.1 package. The upstream license
and platform implementations are retained. The local dependency override makes
the patch reproducible on CI without modifying the developer's package cache.

macOS disposal now stops accepting frame jobs, drops queued obsolete work,
drains an in-flight render, explicitly frees the MPV render context, unregisters
the Flutter texture, and only then completes VideoOutputManager.Dispose.
Hardware and software textures release the context idempotently, independently
of Flutter's retained texture references. Worker cancellation clears closures
that could otherwise keep a removed output alive.

Run the worker lifecycle regression test:

```sh
swiftc third_party/media_kit_video/macos/Classes/plugin/common/Worker.swift tools/macos/test_video_worker.swift -o /tmp/bobtv-video-worker-test
/tmp/bobtv-video-worker-test
```
