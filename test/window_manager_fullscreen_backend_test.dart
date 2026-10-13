import 'dart:async';

import 'package:clubtivi/features/player/desktop_fullscreen_session.dart';
import 'package:clubtivi/features/player/window_manager_fullscreen_backend.dart';
import 'package:clubtivi/core/desktop_window_sizing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _advanceAsyncWork() => Future<void>.delayed(Duration.zero);

class _MockNativeWindow {
  final calls = <MethodCall>[];
  bool fullscreen = false;
  bool minimized = false;
  bool maximized = false;
  bool alwaysOnTop = false;
  bool resizable = true;
  bool maximizable = true;
  bool synchronousFullscreen = false;
  bool rejectFloatingFullscreen = false;
  void Function(bool)? onFullscreenRequest;
  Completer<void>? fullscreenReply;
  String titleBarStyle = 'normal';
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
      case 'isResizable':
        return resizable;
      case 'isMaximizable':
        return maximizable;
      case 'setFullScreen':
        final requested = (call.arguments as Map)['isFullScreen'] as bool;
        if (requested && rejectFloatingFullscreen && alwaysOnTop) {
          throw StateError('Native entry attempted from a floating window');
        }
        if (synchronousFullscreen) {
          fullscreen = requested;
          if (fullscreen) maximizable = false;
        }
        onFullscreenRequest?.call(requested);
        if (fullscreenReply != null) await fullscreenReply!.future;
        return true;
      case 'setTitleBarStyle':
        titleBarStyle = (call.arguments as Map)['titleBarStyle'] as String;
        return true;
      case 'setResizable':
        resizable = (call.arguments as Map)['isResizable'] as bool;
        return true;
      case 'setMaximizable':
        maximizable = (call.arguments as Map)['isMaximizable'] as bool;
        return true;
      case 'maximize':
        maximized = true;
        return true;
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
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  late _MockNativeWindow native;
  late WindowManagerFullscreenBackend backend;
  var hasBackend = false;

  setUp(() {
    binding.platformDispatcher.implicitView!.devicePixelRatio = 1;
    native = _MockNativeWindow();
    hasBackend = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, native.handle);
  });

  tearDown(() {
    binding.platformDispatcher.implicitView!.resetDevicePixelRatio();
    if (hasBackend) backend.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  WindowManagerFullscreenBackend createBackend({required bool isMacOS}) {
    hasBackend = true;
    native.synchronousFullscreen = !isMacOS;
    backend = WindowManagerFullscreenBackend(
      isMacOS: isMacOS,
      isWindows: !isMacOS,
      sizing: DesktopWindowSizing(isWindows: !isMacOS, pixelRatio: () => 1),
    );
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
      expect(native.callsTo('setAlwaysOnTop').single.arguments, {
        'isAlwaysOnTop': false,
      });
      expect(native.callsTo('focus'), isEmpty);

      native.fullscreen = true;
      backend.onWindowEnterFullScreen();
      await entering;
      expect(finished, isTrue);
      expect(events, [true]);
      expect(native.callsTo('setAlwaysOnTop'), hasLength(1));
      expect(native.alwaysOnTop, isFalse);
      expect(native.callsTo('focus'), hasLength(1));
      await subscription.cancel();
    },
  );

  test(
    'Mac re-entry repairs the floating state left by an older fullscreen owner',
    () async {
      native.alwaysOnTop = true;
      native.rejectFloatingFullscreen = true;
      createBackend(isMacOS: true);
      native.onFullscreenRequest = (value) {
        native.fullscreen = value;
        if (value) backend.onWindowEnterFullScreen();
      };
      await backend.setFullscreen(true);
      expect(native.fullscreen, isTrue);
      expect(native.alwaysOnTop, isFalse);
      final methods = native.calls.map((call) => call.method).toList();
      expect(
        methods.indexOf('setAlwaysOnTop'),
        lessThan(methods.indexOf('setFullScreen')),
      );
    },
  );

  for (final originalAlwaysOnTop in [false, true]) {
    test(
      'Mac Escape on the channel page allows repeated player re-entry, original top=$originalAlwaysOnTop',
      () async {
        native.alwaysOnTop = originalAlwaysOnTop;
        native.rejectFloatingFullscreen = true;
        for (var cycle = 0; cycle < 4; cycle++) {
          createBackend(isMacOS: true);
          native.onFullscreenRequest = (value) {
            native.fullscreen = value;
            if (value) {
              backend.onWindowEnterFullScreen();
            } else {
              backend.onWindowLeaveFullScreen();
            }
          };
          final session = DesktopFullscreenSession(
            backend: backend,
            onChanged: (_) {},
            onExternalExit: () => fail(
              'The player owner must be disposed before native channel-page Escape',
            ),
          );
          await session.enter();
          expect(native.fullscreen, isTrue);
          expect(native.alwaysOnTop, isFalse);
          await session.exit(keepWindowFullscreen: true);
          session.dispose();
          await _advanceAsyncWork();
          // Native Escape while the channel page owns the fullscreen window.
          // There is deliberately no active player/backend listener here.
          native.fullscreen = false;
          expect(native.alwaysOnTop, isFalse);
        }
        expect(native.callsTo('setFullScreen'), hasLength(4));
        expect(
          native
              .callsTo('setAlwaysOnTop')
              .every((c) => (c.arguments as Map)['isAlwaysOnTop'] == false),
          isTrue,
        );
      },
    );
  }

  test(
    'Mac native exit from the player restores window state before re-entry',
    () async {
      createBackend(isMacOS: true);
      native.rejectFloatingFullscreen = true;
      native.onFullscreenRequest = (value) {
        native.fullscreen = value;
        if (value) {
          backend.onWindowEnterFullScreen();
        } else {
          backend.onWindowLeaveFullScreen();
        }
      };
      late DesktopFullscreenSession session;
      var externalExits = 0;
      session = DesktopFullscreenSession(
        backend: backend,
        onChanged: (_) {},
        onExternalExit: () {
          externalExits++;
          unawaited(session.exit());
        },
      );
      await session.enter();
      native.fullscreen = false;
      backend.onWindowLeaveFullScreen();
      await session.exit();
      expect(externalExits, 1);
      expect(native.alwaysOnTop, isFalse);
      expect(native.callsTo('setFullScreen'), hasLength(1));
      session.dispose();
      await _advanceAsyncWork();
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
    'Mac native Escape cancels pending entry without the ten-second timeout',
    () async {
      createBackend(isMacOS: true);
      final entering = backend.setFullscreen(true);
      final outcome = expectLater(
        entering,
        throwsA(isA<FullscreenEntryCancelled>()),
      );
      await _advanceAsyncWork();
      backend.onWindowLeaveFullScreen();
      await outcome.timeout(const Duration(seconds: 1));
      expect(native.fullscreen, isFalse);
      expect(native.callsTo('focus'), isEmpty);
      expect(native.alwaysOnTop, isFalse);
    },
  );

  test(
    'Mac cancel before the method reply is handled and does not focus the old window',
    () async {
      createBackend(isMacOS: true);
      native.fullscreenReply = Completer<void>();
      final entering = backend.setFullscreen(true);
      final outcome = expectLater(
        entering,
        throwsA(isA<FullscreenEntryCancelled>()),
      );
      await _advanceAsyncWork();
      backend.onWindowLeaveFullScreen();
      await _advanceAsyncWork();
      native.fullscreenReply!.complete();
      await outcome.timeout(const Duration(seconds: 1));
      expect(native.callsTo('focus'), isEmpty);
      expect(native.alwaysOnTop, isFalse);
    },
  );

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

  for (final mac in [true, false]) {
    test(
      'oversized saved ordinary frame fits a 1080p work area on ${mac ? 'Mac' : 'Windows'}',
      () async {
        const screens = MethodChannel(
          'dev.leanflutter.plugins/screen_retriever',
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              screens,
              (_) async => {
                'displays': [
                  {
                    'id': '1',
                    'size': {'width': 1920.0, 'height': 1080.0},
                    'visiblePosition': {'dx': 0.0, 'dy': 24.0},
                    'visibleSize': {'width': 1920.0, 'height': 1016.0},
                    'scaleFactor': 1,
                  },
                ],
              },
            );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(screens, null),
        );
        createBackend(isMacOS: mac);
        await backend.restore(
          const FullscreenWindowSnapshot(
            bounds: Rect.fromLTWH(100, 100, 4000, 2200),
            maximized: false,
            alwaysOnTop: false,
          ),
        );
        final rect = native.callsTo('setBounds').single.arguments as Map;
        expect(rect['width'], 1920);
        expect(rect['height'], 1016);
        expect(rect['x'], 0);
        expect(rect['y'], 24);
      },
    );
  }

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
      expect(native.resizable, isTrue);
      expect(native.maximizable, isTrue);
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

  for (final maximized in [false, true]) {
    test(
      'Windows normal/maximized=$maximized survives repeated fullscreen',
      () async {
        native.maximized = maximized;
        createBackend(isMacOS: false);
        for (var cycle = 0; cycle < 3; cycle++) {
          final saved = await backend.capture();
          await backend.prepareEntry();
          await backend.setFullscreen(true);
          expect(native.fullscreen, isTrue);
          expect(native.titleBarStyle, 'hidden');
          expect(native.maximizable, isFalse);
          await backend.setFullscreen(false);
          await backend.restore(saved);
          expect(native.fullscreen, isFalse);
          expect(native.titleBarStyle, 'normal');
          expect(native.maximizable, isTrue);
          expect(native.resizable, isTrue);
          expect(native.maximized, maximized);
        }
        final methods = native.calls.map((call) => call.method).toList();
        expect(
          methods.indexOf('setTitleBarStyle'),
          lessThan(methods.indexOf('setFullScreen')),
        );
      },
    );
  }

  test(
    'Windows re-entry from channel fullscreen does not save disabled maximize',
    () async {
      native.fullscreen = true;
      native.maximizable = false;
      createBackend(isMacOS: false);
      final saved = await backend.capture();
      expect(saved.wasFullscreen, isTrue);
      expect(saved.maximizable, isTrue);
      await backend.prepareEntry();
      await backend.setFullscreen(true);
      expect(native.titleBarStyle, 'hidden');
      await backend.setFullscreen(false);
      await backend.restore(saved);
      expect(native.maximizable, isTrue);
      expect(native.titleBarStyle, 'normal');
      expect(native.callsTo('setBounds'), isEmpty);
      expect(native.callsTo('maximize'), isEmpty);
    },
  );

  test(
    'Windows keeps fullscreen chrome hidden when returning to channels',
    () async {
      native.maximized = true;
      createBackend(isMacOS: false);
      final session = DesktopFullscreenSession(
        backend: backend,
        onChanged: (_) {},
        onExternalExit: () {},
      );
      await session.enter();
      await session.exit(keepWindowFullscreen: true);
      expect(native.fullscreen, isTrue);
      expect(native.titleBarStyle, 'hidden');
      expect(native.callsTo('setBounds'), isEmpty);
      expect(native.callsTo('setMaximizable'), isEmpty);
      session.dispose();
      await _advanceAsyncWork();
    },
  );

  test('Windows normal-window capability preferences are preserved', () async {
    native.resizable = false;
    native.maximizable = false;
    createBackend(isMacOS: false);
    final saved = await backend.capture();
    await backend.prepareEntry();
    await backend.setFullscreen(true);
    await backend.setFullscreen(false);
    await backend.restore(saved);
    expect(native.resizable, isFalse);
    expect(native.maximizable, isFalse);
  });

  test(
    'Windows synthesizes both completion events when native events are missing',
    () async {
      createBackend(isMacOS: false);
      final events = <bool>[];
      final subscription = backend.fullscreenChanges.listen(events.add);
      await backend.prepareEntry();
      await backend.setFullscreen(true);
      await backend.setFullscreen(false);
      expect(events, [true, false]);
      await subscription.cancel();
    },
  );

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
