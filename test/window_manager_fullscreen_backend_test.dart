import 'dart:async';
import 'dart:ui';

import 'package:clubtivi/features/player/desktop_fullscreen_session.dart';
import 'package:clubtivi/features/player/window_manager_fullscreen_backend.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _advanceAsyncWork() => Future<void>.delayed(Duration.zero);

class _MockNativeWindow {
  final calls = <MethodCall>[];
  bool fullscreen = false;
  bool minimized = false;
  bool maximized = false;
  bool alwaysOnTop = false;
  Rect bounds = const Rect.fromLTWH(20, 40, 1280, 720);

  List<MethodCall> callsTo(String method) =>
      calls.where((call) => call.method == method).toList();

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'getBounds':
        return {
          'x': bounds.left,
          'y': bounds.top,
          'width': bounds.width,
          'height': bounds.height,
        };
      case 'isFullScreen':
        return fullscreen;
      case 'isMinimized':
        return minimized;
      case 'isMaximized':
        return maximized;
      case 'isAlwaysOnTop':
        return alwaysOnTop;
      case 'setAlwaysOnTop':
        alwaysOnTop = (call.arguments as Map)['isAlwaysOnTop'] as bool;
        return true;
      default:
        // In particular, setFullScreen acknowledges only the request. Mac
        // fullscreen completion must still wait for a separate native event.
        return true;
    }
  }
}

const _snapshot = FullscreenWindowSnapshot(
  bounds: Rect.fromLTWH(30, 50, 1024, 640),
  maximized: false,
  alwaysOnTop: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  late _MockNativeWindow native;
  late WindowManagerFullscreenBackend backend;
  var hasBackend = false;

  setUp(() {
    native = _MockNativeWindow();
    hasBackend = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, native.handle);
  });

  tearDown(() {
    if (hasBackend) backend.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  WindowManagerFullscreenBackend createBackend({required bool isMacOS}) {
    hasBackend = true;
    backend = WindowManagerFullscreenBackend(isMacOS: isMacOS);
    return backend;
  }

  test(
    'capture preserves native geometry, maximization and always-on-top',
    () async {
      native.maximized = true;
      native.alwaysOnTop = true;
      createBackend(isMacOS: true);
      final captured = await backend.capture();
      expect(captured.bounds, const Rect.fromLTWH(20, 40, 1280, 720));
      expect(captured.maximized, isTrue);
      expect(captured.alwaysOnTop, isTrue);
    },
  );

  test(
    'Mac entry waits for native completion after method acknowledgement',
    () async {
      createBackend(isMacOS: true);
      final events = <bool>[];
      final subscription = backend.fullscreenChanges.listen(events.add);
      var finished = false;
      final entering = backend.setFullscreen(true).then((_) => finished = true);
      await _advanceAsyncWork();

      expect(native.callsTo('setFullScreen'), hasLength(1));
      expect(finished, isFalse);
      expect(native.callsTo('setAlwaysOnTop'), isEmpty);
      expect(native.callsTo('focus'), isEmpty);

      native.fullscreen = true;
      backend.onWindowEnterFullScreen();
      await entering;
      expect(finished, isTrue);
      expect(events, [true]);
      expect(native.callsTo('setAlwaysOnTop'), hasLength(1));
      expect(native.callsTo('focus'), hasLength(1));
      await subscription.cancel();
    },
  );

  test('Mac exit waits for native leave notification', () async {
    native.fullscreen = true;
    createBackend(isMacOS: true);
    var finished = false;
    final leaving = backend.setFullscreen(false).then((_) => finished = true);
    await _advanceAsyncWork();
    expect(native.callsTo('setFullScreen'), hasLength(1));
    expect(finished, isFalse);

    native.fullscreen = false;
    backend.onWindowLeaveFullScreen();
    await leaving;
    expect(finished, isTrue);
    expect(native.callsTo('setAlwaysOnTop').single.arguments, {
      'isAlwaysOnTop': false,
    });
    expect(native.callsTo('focus'), isEmpty);
    expect(native.callsTo('setBounds'), isEmpty);
    expect(native.callsTo('maximize'), isEmpty);
  });

  test(
    'Mac exit recovers when native state changes without a notification',
    () async {
      native.fullscreen = true;
      createBackend(isMacOS: true);
      final leaving = backend.setFullscreen(false);
      await _advanceAsyncWork();
      native.fullscreen = false;
      await leaving;
      expect(native.callsTo('setFullScreen'), hasLength(1));
      expect(native.callsTo('setAlwaysOnTop').single.arguments, {
        'isAlwaysOnTop': false,
      });
      expect(native.callsTo('setBounds'), isEmpty);
    },
  );

  test(
    'Mac entry recovers when its completion notification is missing',
    () async {
      createBackend(isMacOS: true);
      final entering = backend.setFullscreen(true);
      await _advanceAsyncWork();
      native.fullscreen = true;
      await entering;
      expect(native.callsTo('focus'), hasLength(1));
    },
  );

  test(
    'Mac preparation and restore preserve unchanged maximization and titlebar',
    () async {
      createBackend(isMacOS: true);
      native.maximized = true;
      await backend.prepareEntry();
      await backend.restore(
        const FullscreenWindowSnapshot(
          bounds: Rect.fromLTWH(30, 50, 1024, 640),
          maximized: true,
          alwaysOnTop: false,
        ),
      );
      expect(native.callsTo('setTitleBarStyle'), isEmpty);
      expect(native.callsTo('setBounds'), isEmpty);
      expect(native.callsTo('maximize'), isEmpty);
      expect(native.callsTo('unmaximize'), isEmpty);
      expect(native.callsTo('focus'), isEmpty);
    },
  );

  test(
    'Mac restore repairs a shrunken frame after native fullscreen exit',
    () async {
      createBackend(isMacOS: true);
      final saved = await backend.capture();
      native.bounds = const Rect.fromLTWH(20, 40, 140, 90);
      await backend.restore(saved);
      final arguments = native.callsTo('setBounds').single.arguments as Map;
      expect(arguments['width'], 1280);
      expect(arguments['height'], 720);
      expect(native.callsTo('setTitleBarStyle'), isEmpty);
    },
  );

  test('Mac restore leaves an unchanged ordinary frame alone', () async {
    createBackend(isMacOS: true);
    final saved = await backend.capture();
    await backend.restore(saved);
    expect(native.callsTo('setBounds'), isEmpty);
  });

  test(
    'Mac restore never applies fullscreen bounds to ordinary window',
    () async {
      native.fullscreen = true;
      createBackend(isMacOS: true);
      final saved = await backend.capture();
      native.fullscreen = false;
      native.bounds = const Rect.fromLTWH(20, 40, 1024, 640);
      await backend.restore(saved);
      expect(native.callsTo('setBounds'), isEmpty);
    },
  );

  test(
    'a Mac minimized during entry stays minimized and is never focused',
    () async {
      createBackend(isMacOS: true);
      final events = <bool>[];
      final subscription = backend.fullscreenChanges.listen(events.add);
      final entering = backend.setFullscreen(true);
      await _advanceAsyncWork();
      native.minimized = true;
      backend.onWindowMinimize();
      expect(events, isEmpty);

      native.fullscreen = true;
      backend.onWindowEnterFullScreen();
      await entering;
      await backend.restore(_snapshot);
      expect(native.minimized, isTrue);
      expect(native.callsTo('focus'), isEmpty);
      expect(native.callsTo('restore'), isEmpty);
      expect(native.callsTo('show'), isEmpty);
      expect(native.callsTo('setBounds'), isEmpty);
      expect(native.callsTo('maximize'), isEmpty);
      expect(events, [true]);
      await subscription.cancel();
    },
  );

  test(
    'Windows preparation hides titlebar and restores original bounds',
    () async {
      createBackend(isMacOS: false);
      await backend.prepareEntry();
      await backend.restore(_snapshot);
      expect(
        native
            .callsTo('setTitleBarStyle')
            .map((call) => (call.arguments as Map)['titleBarStyle']),
        ['hidden', 'normal'],
      );
      final bounds = native.callsTo('setBounds').single.arguments as Map;
      expect(bounds['x'], 30);
      expect(bounds['y'], 50);
      expect(bounds['width'], 1024);
      expect(bounds['height'], 640);
      expect(native.callsTo('maximize'), isEmpty);
      expect(native.callsTo('focus'), isEmpty);
    },
  );

  test(
    'Windows restores maximization without a second bounds rewrite',
    () async {
      createBackend(isMacOS: false);
      await backend.restore(
        const FullscreenWindowSnapshot(
          bounds: Rect.fromLTWH(30, 50, 1024, 640),
          maximized: true,
          alwaysOnTop: false,
        ),
      );
      expect(native.callsTo('maximize'), hasLength(1));
      expect(native.callsTo('setBounds'), isEmpty);
      expect(native.callsTo('focus'), isEmpty);
    },
  );

  test('Windows transition does not require a Mac animation event', () async {
    createBackend(isMacOS: false);
    await backend.setFullscreen(true);
    expect(native.callsTo('setFullScreen'), hasLength(1));
    expect(native.callsTo('setAlwaysOnTop'), hasLength(1));
    expect(native.callsTo('focus'), hasLength(1));
  });

  test(
    'Windows restoration never unminimizes, focuses or resizes the window',
    () async {
      native.minimized = true;
      createBackend(isMacOS: false);
      await backend.restore(
        const FullscreenWindowSnapshot(
          bounds: Rect.fromLTWH(30, 50, 1024, 640),
          maximized: true,
          alwaysOnTop: false,
        ),
      );
      expect(native.minimized, isTrue);
      expect(native.callsTo('restore'), isEmpty);
      expect(native.callsTo('show'), isEmpty);
      expect(native.callsTo('focus'), isEmpty);
      expect(native.callsTo('setBounds'), isEmpty);
      expect(native.callsTo('maximize'), isEmpty);
      expect(native.callsTo('setTitleBarStyle'), hasLength(1));
    },
  );

  for (final isMacOS in [true, false]) {
    for (final originalAlwaysOnTop in [true, false]) {
      test(
        '${isMacOS ? 'Mac' : 'Windows'} restores always-on-top=$originalAlwaysOnTop',
        () async {
          createBackend(isMacOS: isMacOS);
          native.alwaysOnTop = !originalAlwaysOnTop;
          await backend.restore(
            FullscreenWindowSnapshot(
              bounds: _snapshot.bounds,
              maximized: false,
              alwaysOnTop: originalAlwaysOnTop,
            ),
          );
          expect(native.alwaysOnTop, originalAlwaysOnTop);
          expect(native.callsTo('setAlwaysOnTop'), hasLength(1));
        },
      );
    }
  }
}
