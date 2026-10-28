// BobTV patch to media_kit 1.2.6. See BOBTV_PATCHES.md and LICENSE.
import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:media_kit/generated/libmpv/bindings.dart' as generated;

/// Blocking libmpv termination must never run on Flutter's UI isolate.
/// Only primitive, already-detached ownership crosses the isolate boundary.
Future<void> disposeNativePlayer(int address, String libraryPath) async {
  // InitializerIsolate's event loop has a two-second shutdown grace period.
  // Preserve upstream's five-second allowance on every native platform.
  await Future<void>.delayed(const Duration(seconds: 5));
  await runNativeDisposalWorker((address, libraryPath));
}

/// Separate entry point permits a real blocking-function heartbeat regression.
/// The pointer is exclusively owned here after renderer/callback teardown.
Future<void> runNativeDisposalWorker((int, String) request) =>
    Isolate.run(() => _terminate(request));

void _terminate((int, String) request) {
  final (address, libraryPath) = request;
  final mpv = generated.MPV(DynamicLibrary.open(libraryPath));
  mpv.mpv_terminate_destroy(Pointer<generated.mpv_handle>.fromAddress(address));
}
