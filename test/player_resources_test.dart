import 'dart:async';

import 'package:clubtivi/core/player_resources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('duplicate disposal owns one native operation', () async {
    final registry = PlayerResourceRegistry();
    final owner = Object();
    final done = Completer<void>();
    var calls = 0;
    registry.register(owner, () {
      calls++;
      return done.future;
    }, 'preview');
    final a = registry.dispose(owner);
    final b = registry.dispose(owner);
    expect(identical(a, b), isTrue);
    expect(calls, 1);
    done.complete();
    await Future.wait([a, b]);
    await registry.dispose(owner);
    expect(calls, 1);
    expect(registry.resourceCount, 0);
  });

  test(
    'caller timeout retains unfinished decoder for the exit barrier',
    () async {
      final registry = PlayerResourceRegistry();
      final owner = Object();
      final done = Completer<void>();
      registry.register(owner, () => done.future, 'old_main');
      await expectLater(
        registry.dispose(owner).timeout(Duration.zero),
        throwsA(isA<TimeoutException>()),
      );
      var drained = false;
      final drain = registry.disposeAll().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      expect(registry.resourceCount, 1);
      expect(
        () => registry.register(Object(), () async {}, 'late'),
        throwsStateError,
      );
      done.complete();
      await drain;
      expect(drained, isTrue);
      expect(registry.resourceCount, 0);
    },
  );

  test('shutdown drains main, warm and detached multi-view decoders', () async {
    final registry = PlayerResourceRegistry();
    final completed = <String>[];
    for (final role in ['main', 'warm', 'preview', 'multi_view']) {
      registry.register(Object(), () async {
        completed.add(role);
      }, role);
    }
    await registry.disposeAll();
    expect(completed, containsAll(['main', 'warm', 'preview', 'multi_view']));
    expect(registry.resourceCount, 0);
    expect(registry.closing, isTrue);
  });

  test(
    'failed native disposal cannot be counted as a completed drain',
    () async {
      final registry = PlayerResourceRegistry();
      registry.register(
        Object(),
        () async => throw StateError('native fixture'),
        'main',
      );
      await expectLater(registry.disposeAll(), throwsStateError);
      expect(registry.resourceCount, 1);
      await expectLater(registry.disposeAll(), throwsStateError);
    },
  );
}
