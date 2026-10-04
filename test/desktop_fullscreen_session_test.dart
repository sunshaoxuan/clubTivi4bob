import 'dart:async';
import 'dart:ui';

import 'package:clubtivi/features/player/desktop_fullscreen_session.dart';
import 'package:flutter_test/flutter_test.dart';

// The platform adapter acknowledges native animation completion. Tests advance
// that transition explicitly, with no dependency on animation durations.
Future<void> _advanceAsyncWork() => Future<void>.delayed(Duration.zero);

class _FakeFullscreenBackend implements FullscreenWindowBackend {
  _FakeFullscreenBackend({this.fullscreen = false});

  final _changes = StreamController<bool>.broadcast(sync: true);
  final disposed = Completer<void>();
  Completer<FullscreenWindowSnapshot>? captureGate;
  Completer<void>? postEntryGate;
  Completer<void>? _pendingTransition;
  final commands = <bool>[];
  final restoredSnapshots = <FullscreenWindowSnapshot>[];
  final operations = <String>[];
  final snapshot = const FullscreenWindowSnapshot(
    bounds: Rect.fromLTWH(40, 70, 1280, 720),
    maximized: false,
    alwaysOnTop: true,
  );
  bool fullscreen;
  bool minimized = false;
  int captureCount = 0;
  int disposeCount = 0;

  @override
  Stream<bool> get fullscreenChanges => _changes.stream;

  @override
  Future<FullscreenWindowSnapshot> capture() async {
    captureCount++;
    operations.add('capture');
    if (captureGate != null) return captureGate!.future;
    return snapshot;
  }

  @override
  Future<bool> isFullscreen() async => fullscreen;

  @override
  Future<void> prepareEntry() async {
    operations.add('prepare-entry');
  }

  @override
  Future<void> setFullscreen(bool value) async {
    if (fullscreen == value) return;
    commands.add(value);
    operations.add('request-$value');
    expect(_pendingTransition, isNull);
    _pendingTransition = Completer<void>();
    await _pendingTransition!.future;
    if (value && postEntryGate != null) await postEntryGate!.future;
  }

  void completeNativeTransition(bool value) {
    fullscreen = value;
    operations.add('complete-$value');
    _changes.add(value);
    final pending = _pendingTransition;
    _pendingTransition = null;
    pending?.complete();
  }

  void minimize() {
    minimized = true;
    operations.add('minimize');
    // Miniaturization is independent of fullscreen, so it emits no change.
  }

  void restoreFromMinimize() {
    minimized = false;
    operations.add('restore-from-minimize');
  }

  @override
  Future<void> restore(FullscreenWindowSnapshot snapshot) async {
    operations.add('restore-snapshot');
    restoredSnapshots.add(snapshot);
  }

  @override
  void dispose() {
    disposeCount++;
    operations.add('dispose-backend');
    unawaited(_changes.close());
    if (!disposed.isCompleted) disposed.complete();
  }
}

void main() {
  group('DesktopFullscreenSession', () {
    test('return to channels preserves fullscreen through disposal', () async {
      final backend = _FakeFullscreenBackend();
      final session = DesktopFullscreenSession(
        backend: backend,
        onChanged: (_) {},
        onExternalExit: () {},
      );
      final entering = session.enter();
      await _advanceAsyncWork();
      backend.completeNativeTransition(true);
      await entering;
      await session.exit(keepWindowFullscreen: true);
      expect(backend.fullscreen, isTrue);
      expect(backend.commands, [true]);
      expect(backend.restoredSnapshots, isEmpty);
      session.dispose();
      await backend.disposed.future;
      expect(backend.fullscreen, isTrue);
      expect(backend.commands, [true]);
      expect(backend.restoredSnapshots, isEmpty);
    });

    test('return during entry finishes animation without exiting window', () async {
      final backend = _FakeFullscreenBackend();
      final session = DesktopFullscreenSession(
        backend: backend,
        onChanged: (_) {},
        onExternalExit: () {},
      );
      final entering = session.enter();
      await _advanceAsyncWork();
      final leaving = session.exit(keepWindowFullscreen: true);
      backend.completeNativeTransition(true);
      await entering;
      await leaving;
      session.dispose();
      await backend.disposed.future;
      expect(backend.fullscreen, isTrue);
      expect(backend.commands, [true]);
      expect(backend.restoredSnapshots, isEmpty);
    });

    test(
      'immediate exit waits for native enter and leave completion',
      () async {
        final backend = _FakeFullscreenBackend();
        final changes = <bool>[];
        var externalExits = 0;
        final session = DesktopFullscreenSession(
          backend: backend,
          onChanged: changes.add,
          onExternalExit: () => externalExits++,
        );

        var enterFinished = false;
        var exitFinished = false;
        final entering = session.enter().then((_) => enterFinished = true);
        await _advanceAsyncWork();
        final leaving = session.exit().then((_) => exitFinished = true);
        await _advanceAsyncWork();

        expect(backend.commands, [true]);
        expect(backend.restoredSnapshots, isEmpty);
        expect(enterFinished, isFalse);
        expect(exitFinished, isFalse);

        backend.completeNativeTransition(true);
        await entering;
        await _advanceAsyncWork();
        expect(backend.commands, [true, false]);
        expect(backend.restoredSnapshots, isEmpty);
        expect(exitFinished, isFalse);

        backend.completeNativeTransition(false);
        await leaving;
        expect(backend.restoredSnapshots, [backend.snapshot]);
        expect(changes, [false]);
        expect(externalExits, 0);
        expect(
          backend.operations.indexOf('restore-snapshot'),
          greaterThan(backend.operations.indexOf('complete-false')),
        );
        session.dispose();
        await backend.disposed.future;
      },
    );

    test('duplicate exits share one future and restore once', () async {
      final backend = _FakeFullscreenBackend();
      final session = DesktopFullscreenSession(
        backend: backend,
        onChanged: (_) {},
        onExternalExit: () {},
      );
      final entering = session.enter();
      await _advanceAsyncWork();
      backend.completeNativeTransition(true);
      await entering;

      final firstExit = session.exit();
      final secondExit = session.exit();
      expect(identical(firstExit, secondExit), isTrue);
      await _advanceAsyncWork();
      expect(backend.commands, [true, false]);
      backend.completeNativeTransition(false);
      await Future.wait([firstExit, secondExit]);

      await session.exit();
      expect(backend.commands, [true, false]);
      expect(backend.restoredSnapshots, hasLength(1));
      session.dispose();
      await backend.disposed.future;
    });

    test(
      'exit before capture finishes cancels entry without a native toggle',
      () async {
        final backend = _FakeFullscreenBackend()
          ..captureGate = Completer<FullscreenWindowSnapshot>();
        final changes = <bool>[];
        var externalExits = 0;
        final session = DesktopFullscreenSession(
          backend: backend,
          onChanged: changes.add,
          onExternalExit: () => externalExits++,
        );
        final entering = session.enter();
        final leaving = session.exit();
        await _advanceAsyncWork();
        expect(backend.commands, isEmpty);
        expect(backend.restoredSnapshots, isEmpty);

        backend.captureGate!.complete(backend.snapshot);
        await Future.wait([entering, leaving]);
        expect(backend.commands, isEmpty);
        expect(backend.operations, isNot(contains('prepare-entry')));
        expect(backend.restoredSnapshots, [backend.snapshot]);
        expect(changes, [false]);
        expect(externalExits, 0);
        session.dispose();
        await backend.disposed.future;
      },
    );

    test(
      'external leave notifies once and avoids a redundant toggle',
      () async {
        final backend = _FakeFullscreenBackend();
        final changes = <bool>[];
        var externalExits = 0;
        final session = DesktopFullscreenSession(
          backend: backend,
          onChanged: changes.add,
          onExternalExit: () => externalExits++,
        );
        final entering = session.enter();
        await _advanceAsyncWork();
        backend.completeNativeTransition(true);
        await entering;

        backend.completeNativeTransition(false);
        backend.completeNativeTransition(false);
        await _advanceAsyncWork();
        expect(externalExits, 1);
        await session.exit();

        expect(backend.commands, [true]);
        expect(backend.restoredSnapshots, [backend.snapshot]);
        expect(changes, [true, false]);
        session.dispose();
        await backend.disposed.future;
      },
    );

    test(
      'native exit during post-entry work never publishes stale fullscreen',
      () async {
        final backend = _FakeFullscreenBackend()
          ..postEntryGate = Completer<void>();
        final changes = <bool>[];
        var externalExits = 0;
        late DesktopFullscreenSession session;
        session = DesktopFullscreenSession(
          backend: backend,
          onChanged: changes.add,
          onExternalExit: () {
            externalExits++;
            unawaited(session.exit());
          },
        );
        final entering = session.enter();
        await _advanceAsyncWork();
        backend.completeNativeTransition(true);
        await _advanceAsyncWork();
        expect(changes, isEmpty);

        backend.completeNativeTransition(false);
        backend.completeNativeTransition(false);
        await _advanceAsyncWork();
        expect(externalExits, 1);
        expect(backend.commands, [true]);
        expect(backend.restoredSnapshots, isEmpty);

        backend.postEntryGate!.complete();
        await entering;
        await session.exit();
        expect(changes, [false]);
        expect(backend.commands, [true]);
        expect(backend.restoredSnapshots, [backend.snapshot]);
        session.dispose();
        await backend.disposed.future;
      },
    );

    test(
      'disposal during entry drains native transitions without navigation',
      () async {
        final backend = _FakeFullscreenBackend();
        var externalExits = 0;
        final session = DesktopFullscreenSession(
          backend: backend,
          onChanged: (_) {},
          onExternalExit: () => externalExits++,
        );
        final entering = session.enter();
        await _advanceAsyncWork();
        session.dispose();
        session.dispose();
        await _advanceAsyncWork();

        expect(backend.commands, [true]);
        expect(backend.disposeCount, 0);
        backend.completeNativeTransition(true);
        await entering;
        await _advanceAsyncWork();
        expect(backend.commands, [true, false]);
        expect(backend.restoredSnapshots, isEmpty);

        backend.completeNativeTransition(false);
        await backend.disposed.future;
        expect(externalExits, 0);
        expect(backend.restoredSnapshots, [backend.snapshot]);
        expect(backend.disposeCount, 1);
      },
    );

    test('disposal during exit shares the pending cleanup', () async {
      final backend = _FakeFullscreenBackend();
      var externalExits = 0;
      final session = DesktopFullscreenSession(
        backend: backend,
        onChanged: (_) {},
        onExternalExit: () => externalExits++,
      );
      final entering = session.enter();
      await _advanceAsyncWork();
      backend.completeNativeTransition(true);
      await entering;

      final leaving = session.exit();
      await _advanceAsyncWork();
      session.dispose();
      await _advanceAsyncWork();
      expect(backend.commands, [true, false]);
      expect(backend.disposeCount, 0);

      backend.completeNativeTransition(false);
      await leaving;
      await backend.disposed.future;
      expect(externalExits, 0);
      expect(backend.restoredSnapshots, hasLength(1));
      expect(backend.disposeCount, 1);
    });

    test(
      'an already fullscreen window captures and restores its snapshot',
      () async {
        final backend = _FakeFullscreenBackend(fullscreen: true);
        final session = DesktopFullscreenSession(
          backend: backend,
          onChanged: (_) {},
          onExternalExit: () {},
        );
        await session.enter();
        expect(backend.captureCount, 1);
        expect(backend.commands, isEmpty);

        final leaving = session.exit();
        await _advanceAsyncWork();
        expect(backend.commands, [false]);
        expect(backend.restoredSnapshots, isEmpty);
        backend.completeNativeTransition(false);
        await leaving;
        expect(backend.restoredSnapshots, [backend.snapshot]);
        session.dispose();
        await backend.disposed.future;
      },
    );

    test(
      'minimize and restore leave the fullscreen session unchanged',
      () async {
        final backend = _FakeFullscreenBackend();
        final changes = <bool>[];
        var externalExits = 0;
        final session = DesktopFullscreenSession(
          backend: backend,
          onChanged: changes.add,
          onExternalExit: () => externalExits++,
        );
        final entering = session.enter();
        await _advanceAsyncWork();
        backend.completeNativeTransition(true);
        await entering;

        backend.minimize();
        await _advanceAsyncWork();
        expect(backend.fullscreen, isTrue);
        expect(backend.minimized, isTrue);
        expect(backend.commands, [true]);
        expect(backend.restoredSnapshots, isEmpty);
        expect(changes, [true]);
        expect(externalExits, 0);

        backend.restoreFromMinimize();
        await _advanceAsyncWork();
        expect(backend.fullscreen, isTrue);
        expect(changes, [true]);

        final leaving = session.exit();
        await _advanceAsyncWork();
        backend.completeNativeTransition(false);
        await leaving;
        expect(backend.restoredSnapshots, hasLength(1));
        session.dispose();
        await backend.disposed.future;
      },
    );
  });
}
