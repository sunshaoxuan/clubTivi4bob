import 'dart:async';
import 'dart:ui';

import 'package:clubtivi/features/player/desktop_fullscreen_session.dart';
import 'package:clubtivi/features/player/window_playback_session.dart';
import 'package:flutter_test/flutter_test.dart';

class _Backend implements FullscreenWindowBackend {
  final changes = StreamController<bool>.broadcast(sync: true);
  final commands = <bool>[];
  final restored = <FullscreenWindowSnapshot>[];
  FullscreenWindowSnapshot snapshot = const FullscreenWindowSnapshot(
    bounds: Rect.fromLTWH(40, 60, 984, 611),
    maximized: false,
    alwaysOnTop: false,
  );
  Completer<void>? entryGate;
  bool fullscreen = false;
  bool failEntry = false;
  bool disposed = false;

  @override
  Stream<bool> get fullscreenChanges => changes.stream;
  @override
  Future<FullscreenWindowSnapshot> capture() async => snapshot;
  @override
  Future<bool> isFullscreen() async => fullscreen;
  @override
  Future<void> prepareEntry() async {}
  @override
  Future<void> restore(FullscreenWindowSnapshot snapshot) async {
    restored.add(snapshot);
  }

  @override
  Future<void> setFullscreen(bool value) async {
    commands.add(value);
    if (value) {
      await entryGate?.future;
      if (failEntry) throw StateError('fixture entry failed');
    }
    fullscreen = value;
    changes.add(value);
  }

  void nativeExit() {
    fullscreen = false;
    changes.add(false);
  }

  @override
  void dispose() {
    disposed = true;
    unawaited(changes.close());
  }
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'window playback and its exit perform no native window operations',
    () async {
      var backendCreations = 0;
      final session = WindowPlaybackSession(
        createBackend: () {
          backendCreations++;
          return _Backend();
        },
        onChanged: (_) {},
      );
      expect(session.isFullscreen, isFalse);
      expect(session.fullscreenRequested, isFalse);
      await session.exitFullscreen();
      session.dispose();
      await _flush();
      expect(backendCreations, 0);
    },
  );

  test(
    'fullscreen toggles return to the same window playback session',
    () async {
      final backends = <_Backend>[];
      final changes = <bool>[];
      final session = WindowPlaybackSession(
        createBackend: () {
          final backend = _Backend();
          if (backends.isNotEmpty) {
            backend.snapshot = const FullscreenWindowSnapshot(
              bounds: Rect.fromLTWH(-1400, 80, 1200, 800),
              maximized: true,
              alwaysOnTop: false,
            );
          }
          backends.add(backend);
          return backend;
        },
        onChanged: changes.add,
      );
      addTearDown(session.dispose);
      for (var cycle = 0; cycle < 2; cycle++) {
        await session.toggleFullscreen();
        expect(session.isFullscreen, isTrue);
        expect(session.fullscreenRequested, isTrue);
        final backend = backends.last;
        await session.toggleFullscreen();
        await _flush();
        expect(session.isFullscreen, isFalse);
        expect(session.fullscreenRequested, isFalse);
        expect(backend.commands, [true, false]);
        expect(backend.restored, [backend.snapshot]);
        expect(backend.disposed, isTrue);
      }
      expect(changes, [true, false, true, false]);
      expect(backends.last.restored.single.bounds.left, -1400);
    },
  );

  test('native fullscreen exit keeps the window player open', () async {
    final backend = _Backend();
    final changes = <bool>[];
    final session = WindowPlaybackSession(
      createBackend: () => backend,
      onChanged: changes.add,
    );
    addTearDown(session.dispose);
    await session.enterFullscreen();
    backend.nativeExit();
    await _flush();
    expect(session.isFullscreen, isFalse);
    expect(session.fullscreenRequested, isFalse);
    expect(backend.commands, [true]);
    expect(backend.restored, [backend.snapshot]);
    expect(changes, [true, false]);
  });

  test('Windows restore control returns to window playback', () async {
    final backend = _Backend();
    final session = WindowPlaybackSession(
      createBackend: () => backend,
      onChanged: (_) {},
    );
    addTearDown(session.dispose);
    await session.enterFullscreen();
    expect(await DesktopFullscreenSession.restoreActiveWindow(), isTrue);
    expect(session.fullscreenRequested, isFalse);
    expect(backend.commands, [true, false]);
    expect(await DesktopFullscreenSession.restoreActiveWindow(), isFalse);
  });

  test('fast exit during native entry restores geometry once', () async {
    final backend = _Backend()..entryGate = Completer<void>();
    final session = WindowPlaybackSession(
      createBackend: () => backend,
      onChanged: (_) {},
    );
    addTearDown(session.dispose);
    final entering = session.toggleFullscreen();
    await _flush();
    expect(backend.commands, [true]);
    final leaving = session.toggleFullscreen();
    final duplicateExit = session.exitFullscreen();
    expect(identical(leaving, duplicateExit), isTrue);
    await _flush();
    backend.entryGate!.complete();
    await Future.wait([entering, leaving, duplicateExit]);
    expect(backend.commands, [true, false]);
    expect(backend.restored, [backend.snapshot]);
    expect(session.fullscreenRequested, isFalse);
  });

  test('immediate cancellation avoids entering native fullscreen', () async {
    final backend = _Backend();
    final session = WindowPlaybackSession(
      createBackend: () => backend,
      onChanged: (_) {},
    );
    addTearDown(session.dispose);
    final entering = session.toggleFullscreen();
    await session.toggleFullscreen();
    await entering;
    expect(backend.commands, isEmpty);
    expect(backend.restored, [backend.snapshot]);
    expect(session.fullscreenRequested, isFalse);
  });

  test('failed entry restores window and permits a later retry', () async {
    final backends = <_Backend>[];
    final session = WindowPlaybackSession(
      createBackend: () {
        final backend = _Backend()..failEntry = backends.isEmpty;
        backends.add(backend);
        return backend;
      },
      onChanged: (_) {},
    );
    addTearDown(session.dispose);
    await expectLater(session.enterFullscreen(), throwsStateError);
    expect(session.fullscreenRequested, isFalse);
    expect(backends.first.restored, [backends.first.snapshot]);
    await session.enterFullscreen();
    expect(session.isFullscreen, isTrue);
    await session.exitFullscreen();
    expect(backends, hasLength(2));
  });

  test(
    'disposal during entry waits for native restoration without notifying',
    () async {
      final backend = _Backend()..entryGate = Completer<void>();
      final changes = <bool>[];
      final session = WindowPlaybackSession(
        createBackend: () => backend,
        onChanged: changes.add,
      );
      final entering = session.enterFullscreen();
      await _flush();
      session.dispose();
      backend.entryGate!.complete();
      await entering;
      await _flush();
      expect(backend.commands, [true, false]);
      expect(backend.restored, [backend.snapshot]);
      expect(backend.disposed, isTrue);
      expect(changes, isEmpty);
      await session.toggleFullscreen();
      expect(backend.commands, [true, false]);
    },
  );

  test('same channel keeps its decoder even after failover or pause', () {
    expect(
      WindowPlaybackSession.canReusePlayback(
        activeUrl: 'https://example.com/failover.m3u8',
        activeChannelId: 'astro',
        selectedChannelId: 'astro',
        selectedUrls: ['https://example.com/primary.m3u8'],
      ),
      isTrue,
    );
  });

  test('distinct known channel identities do not reuse a shared URL', () {
    expect(
      WindowPlaybackSession.canReusePlayback(
        activeUrl: 'https://example.com/live.m3u8',
        activeChannelId: 'first',
        selectedChannelId: 'second',
        selectedUrls: ['https://example.com/live.m3u8'],
      ),
      isFalse,
    );
  });

  test('missing identity requires an exact URL without normalization', () {
    bool reuse(String? url) => WindowPlaybackSession.canReusePlayback(
      activeUrl: url,
      activeChannelId: null,
      selectedChannelId: 'astro',
      selectedUrls: ['http://example.com:8880/live?version=1'],
    );
    expect(reuse('http://example.com:8880/live?version=1'), isTrue);
    expect(reuse('http://example.com:8880/live?version=2'), isFalse);
    expect(reuse('https://example.com:8880/live?version=1'), isFalse);
    expect(reuse(null), isFalse);
    expect(reuse(''), isFalse);
  });
}
