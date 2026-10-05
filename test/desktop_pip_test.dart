import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/features/player/desktop_fullscreen_session.dart';
import 'package:clubtivi/features/player/desktop_pip_session.dart';
import 'package:clubtivi/features/player/desktop_pip_controls.dart';

class Backend implements DesktopPipBackend {
  final calls = <String>[];
  Completer<void>? ready;
  bool failCompact = false, failSave = false, failRestore = false;
  @override
  Future<FullscreenWindowSnapshot> capture() async {
    calls.add('capture');
    return const FullscreenWindowSnapshot(
      bounds: Rect.fromLTWH(0, 0, 1000, 650),
      maximized: true,
      alwaysOnTop: false,
    );
  }

  @override
  Future<void> compact() async {
    calls.add('compact');
    await ready?.future;
    if (failCompact) throw StateError('compact');
  }

  @override
  Future<void> rememberBounds() async {
    calls.add('save');
    if (failSave) throw StateError('save');
  }

  @override
  Future<void> restore(FullscreenWindowSnapshot snapshot) async {
    calls.add('restore');
    if (failRestore) {
      failRestore = false;
      throw StateError('restore');
    }
    expect(snapshot.maximized, true);
    expect(snapshot.bounds.width, 1000);
  }
}

void main() {
  test('Repeated entry and exit have one window owner', () async {
    final backend = Backend();
    final session = DesktopPipSession(backend);
    await Future.wait([session.enter(), session.enter()]);
    await Future.wait([session.exit(), session.exit()]);
    expect(backend.calls, ['capture', 'compact', 'save', 'restore']);
  });
  test('Exit during entry waits for the native operation', () async {
    final backend = Backend()..ready = Completer<void>();
    final session = DesktopPipSession(backend);
    final entry = session.enter();
    final exit = session.exit();
    await Future<void>.delayed(Duration.zero);
    expect(backend.calls, ['capture', 'compact']);
    backend.ready!.complete();
    await entry;
    await exit;
    expect(backend.calls.last, 'restore');
  });
  test(
    'Failed entry restores and does not restore twice on disposal',
    () async {
      final backend = Backend()..failCompact = true;
      final session = DesktopPipSession(backend);
      await expectLater(session.enter(), throwsStateError);
      await session.exit();
      expect(backend.calls, ['capture', 'compact', 'restore']);
    },
  );
  test('Preference failure cannot trap the user in PiP', () async {
    final backend = Backend()..failSave = true;
    final session = DesktopPipSession(backend);
    await session.enter();
    await session.exit();
    expect(backend.calls.last, 'restore');
  });
  test('Native restoration failures can be retried', () async {
    final backend = Backend();
    final session = DesktopPipSession(backend);
    await session.enter();
    backend.failRestore = true;
    await expectLater(session.exit(), throwsStateError);
    await session.exit();
    expect(backend.calls.where((value) => value == 'restore').length, 2);
  });
  const main = Rect.fromLTWH(100, 100, 1000, 650);
  const screen = Rect.fromLTWH(0, 0, 1920, 1040);
  const second = Rect.fromLTWH(-1280, 0, 1280, 720);
  test('Default is bottom-right inside the usable display area', () {
    final bounds = desktopPipBounds([screen], main);
    expect(bounds.right, 1900);
    expect(bounds.bottom, 1020);
    expect(bounds.width, 420);
  });
  test('Remembers size and coordinates on a negative-coordinate monitor', () {
    const saved = Rect.fromLTWH(-900, 120, 450, 260);
    expect(desktopPipBounds([screen, second], main, remembered: saved), saved);
  });
  test('Disconnected displays recover on the current monitor', () {
    const saved = Rect.fromLTWH(-900, 120, 450, 260);
    expect(
      desktopPipBounds([screen], main, remembered: saved),
      desktopPipBounds([screen], main),
    );
  });
  test('Partially off-screen windows are clamped without changing monitor', () {
    final bounds = desktopPipBounds(
      [screen],
      main,
      remembered: const Rect.fromLTWH(1800, 950, 640, 480),
    );
    expect(bounds.right, 1920);
    expect(bounds.bottom, 1040);
  });
  testWidgets('Smallest PiP has usable mouse controls without overflow', (
    tester,
  ) async {
    var expanded = 0, returned = 0, closed = 0;
    double volume = 100;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 220,
            child: DesktopPipControls(
              title: 'CCTV-5 体育',
              volume: volume,
              onVolume: (value) => volume = value,
              onExpand: () => expanded++,
              onReturn: () => returned++,
              onClose: () => closed++,
              onDrag: () {},
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('放大播放'));
    await tester.tap(find.text('返回频道'));
    await tester.tap(find.byTooltip('退出 BobTV'));
    await tester.tap(find.byTooltip('静音'));
    expect([expanded, returned, closed], [1, 1, 1]);
    expect(volume, 0);
  });
}
