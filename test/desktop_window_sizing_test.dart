import 'package:clubtivi/core/desktop_window_sizing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const window = MethodChannel('window_manager');
  const screens = MethodChannel('dev.leanflutter.plugins/screen_retriever');
  const events = MethodChannel(
    'dev.leanflutter.plugins/screen_retriever_event',
  );
  late DesktopWindowSizing sizing;
  late Rect bounds;
  late List<MethodCall> calls;
  bool fullscreen = false, minimized = false, maximized = false;
  void Function()? minimumHook;
  setUp(() {
    binding.platformDispatcher.implicitView!.devicePixelRatio = 1;
    bounds = const Rect.fromLTWH(0, 0, 3840, 2160);
    calls = [];
    fullscreen = minimized = maximized = false;
    minimumHook = null;
    sizing = DesktopWindowSizing(
      isWindows: true,
      pixelRatio: () =>
          binding.platformDispatcher.implicitView!.devicePixelRatio,
    );
    messenger.setMockMethodCallHandler(window, (call) async {
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
        case 'unmaximize':
          maximized = false;
          return true;
        case 'setMinimumSize':
          minimumHook?.call();
          return true;
        case 'setBounds':
          final args = call.arguments as Map;
          bounds = Rect.fromLTWH(
            args['x'] as double,
            args['y'] as double,
            args['width'] as double,
            args['height'] as double,
          );
          return true;
        default:
          return true;
      }
    });
    messenger.setMockMethodCallHandler(
      screens,
      (_) async => {
        'displays': [
          {
            'id': '1',
            'size': {'width': 3840.0, 'height': 2160.0},
            'visiblePosition': {'dx': 0.0, 'dy': 24.0},
            'visibleSize': {'width': 3840.0, 'height': 2096.0},
            'scaleFactor': 1,
          },
        ],
      },
    );
    messenger.setMockMethodCallHandler(events, (_) async => null);
  });
  tearDown(() async {
    sizing.dispose();
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(window, null);
    messenger.setMockMethodCallHandler(screens, null);
    messenger.setMockMethodCallHandler(events, null);
    binding.platformDispatcher.implicitView!.resetDevicePixelRatio();
  });
  test('startup uses modest outer frame and does not maximize', () async {
    maximized = true;
    await sizing.start();
    expect(bounds.size, const Size(1000, 650));
    expect(bounds.top, 24);
    expect(calls.where((c) => c.method == 'unmaximize'), hasLength(1));
    expect(calls.where((c) => c.method == 'maximize'), isEmpty);
  });
  test(
    'ordinary restored frame is limited, unchanged minimum is not repeatedly set',
    () async {
      await sizing.start();
      calls.clear();
      bounds = const Rect.fromLTWH(0, 24, 3840, 2096);
      await sizing.normalize();
      expect(bounds.size, const Size(1920, 1280));
      await sizing.normalize();
      expect(calls.where((c) => c.method == 'setBounds'), hasLength(1));
      expect(calls.where((c) => c.method == 'setMinimumSize'), isEmpty);
    },
  );
  for (final state in ['fullscreen', 'minimized', 'maximized']) {
    test('normalization leaves $state untouched', () async {
      await sizing.start();
      calls.clear();
      fullscreen = state == 'fullscreen';
      minimized = state == 'minimized';
      maximized = state == 'maximized';
      await sizing.normalize();
      expect(
        calls.where(
          (c) => c.method == 'setBounds' || c.method == 'setMinimumSize',
        ),
        isEmpty,
      );
    });
  }
  test(
    'nested fullscreen and PiP leases do not resize a compact window',
    () async {
      await sizing.start();
      calls.clear();
      final releaseFullscreen = sizing.suspend();
      final releasePip = sizing.suspend();
      bounds = const Rect.fromLTWH(3000, 1500, 420, 280);
      await sizing.normalize();
      releaseFullscreen();
      await sizing.normalize();
      expect(bounds.width, 420);
      expect(calls.where((c) => c.method == 'setBounds'), isEmpty);
      bounds = const Rect.fromLTWH(100, 100, 3000, 2000);
      releasePip();
      releasePip();
      await sizing.normalize();
      expect(bounds.size, const Size(1920, 1280));
    },
  );
  test(
    'fullscreen starting during a minimum-size call cancels pending resize',
    () async {
      await sizing.start();
      calls.clear();
      void Function()? release;
      final reset = sizing.suspend();
      reset();
      minimumHook = () {
        release = sizing.suspend();
        fullscreen = true;
      };
      bounds = const Rect.fromLTWH(0, 24, 3000, 2000);
      await sizing.normalize();
      expect(calls.where((c) => c.method == 'setBounds'), isEmpty);
      release?.call();
    },
  );
  test(
    'mixed Windows display DPI uses one physical coordinate space',
    () async {
      binding.platformDispatcher.implicitView!.devicePixelRatio = 2;
      messenger.setMockMethodCallHandler(
        screens,
        (_) async => {
          'displays': [
            {
              'id': 'primary',
              'size': {'width': 1920.0, 'height': 1080.0},
              'visiblePosition': {'dx': 0.0, 'dy': 0.0},
              'visibleSize': {'width': 1920.0, 'height': 1040.0},
              'scaleFactor': 2,
            },
            {
              'id': 'secondary',
              'size': {'width': 1920.0, 'height': 1080.0},
              'visiblePosition': {'dx': 3840.0, 'dy': 0.0},
              'visibleSize': {'width': 1920.0, 'height': 1040.0},
              'scaleFactor': 1,
            },
          ],
        },
      );
      final rect = await sizing.constrain(
        const Rect.fromLTWH(2000, 0, 1600, 900),
      );
      expect(rect.left, 1920);
      expect(rect.size, const Size(960, 520));
    },
  );
}
