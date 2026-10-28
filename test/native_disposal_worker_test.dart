import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import '../third_party/media_kit/lib/src/player/native/core/native_disposal.dart';

void main() {
  test(
    'blocking native termination leaves the calling isolate responsive',
    () async {
      final supplied =
          Platform.environment['BOBTV_NATIVE_DISPOSAL_TEST_LIBRARY'];
      final directory = await Directory.systemTemp.createTemp(
        'bobtv-disposal-',
      );
      try {
        final library =
            supplied ??
            '${directory.path}/${Platform.isMacOS ? 'fixture.dylib' : 'fixture.so'}';
        if (supplied == null) {
          expect(
            Platform.isWindows,
            isFalse,
            reason: 'Windows QA must supply its compiled test-only DLL',
          );
          final compile = await Process.run('cc', [
            Platform.isMacOS ? '-dynamiclib' : '-shared',
            '-fPIC',
            'tools/diagnostics/native_disposal_fixture.c',
            '-o',
            library,
          ]);
          expect(compile.exitCode, 0, reason: '${compile.stderr}');
        }
        final watch = Stopwatch()..start();
        var ticks = 0;
        var ticksDuringNativeCall = 0;
        var completed = false;
        final state = calloc<Int32>();
        final heartbeat = Timer.periodic(const Duration(milliseconds: 20), (_) {
          ticks++;
          if (state.value == 1) ticksDuringNativeCall++;
        });
        try {
          final disposal = disposeNativePlayer(state.address, library).then((
            _,
          ) {
            completed = true;
          });
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(completed, isFalse);
          await disposal.timeout(const Duration(seconds: 15));
          expect(completed, isTrue);
          expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(5700));
          expect(ticks, greaterThan(100));
          expect(state.value, 2);
          expect(
            ticksDuringNativeCall,
            greaterThanOrEqualTo(2),
            reason: 'UI timers must run while C is still blocked, not after it',
          );
        } finally {
          heartbeat.cancel();
          // The disposal future has completed and no native thread owns state.
          // A failed timeout intentionally leaks this tiny fixture allocation
          // rather than free memory still used by its test-only C function.
          if (completed) calloc.free(state);
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('core ownership is released after renderers and callbacks', () {
    final source = File(
      'third_party/media_kit/lib/src/player/native/player/real.dart',
    ).readAsStringSync();
    final disposal = source.substring(
      source.indexOf('  Future<void> dispose('),
      source.indexOf('  /// Opens a [Media]'),
    );
    expect(
      disposal.indexOf('await super.dispose();'),
      lessThan(disposal.indexOf('Initializer(mpv).dispose(ctx);')),
    );
    expect(
      disposal.indexOf('Initializer(mpv).dispose(ctx);'),
      lessThan(disposal.indexOf('await disposeNativePlayer(')),
    );
    final detachedBody = disposal.substring(
      disposal.indexOf('    Future<void> function() async {'),
      disposal.indexOf('    if (synchronized) {'),
    );
    expect(detachedBody, isNot(contains('disposeNativePlayer(')));
    expect(
      disposal.indexOf('await lock.synchronized(function);'),
      lessThan(disposal.indexOf('await disposeNativePlayer(')),
    );
    expect(disposal, isNot(contains('mpv_terminate_destroy(')));
  });
}
