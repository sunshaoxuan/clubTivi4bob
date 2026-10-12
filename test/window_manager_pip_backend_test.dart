import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clubtivi/features/player/window_manager_pip_backend.dart';
import 'package:clubtivi/core/desktop_window_sizing.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => binding.platformDispatcher.implicitView!.devicePixelRatio = 1);
  tearDown(
    () => binding.platformDispatcher.implicitView!.resetDevicePixelRatio(),
  );
  const window = MethodChannel('window_manager');
  const screens = MethodChannel('dev.leanflutter.plugins/screen_retriever');
  for (final mac in [false, true]) {
    test(
      'Native PiP restores geometry, pinning and chrome on ${mac ? 'Mac' : 'Windows'}',
      () async {
        final calls = <MethodCall>[];
        SharedPreferences.setMockInitialValues({});
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(window, (call) async {
          calls.add(call);
          if (call.method == 'getBounds') {
            return {'x': 100.0, 'y': 100.0, 'width': 1000.0, 'height': 650.0};
          }
          if (call.method == 'isResizable') return true;
          if (call.method == 'isMaximizable') return true;
          if (call.method.startsWith('is')) return false;
          return true;
        });
        messenger.setMockMethodCallHandler(
          screens,
          (_) async => {
            'displays': [
              {
                'id': '1',
                'size': {'width': 1920.0, 'height': 1080.0},
                'visiblePosition': {'dx': 0.0, 'dy': 0.0},
                'visibleSize': {'width': 1920.0, 'height': 1040.0},
              },
            ],
          },
        );
        addTearDown(() {
          messenger.setMockMethodCallHandler(window, null);
          messenger.setMockMethodCallHandler(screens, null);
        });
        final backend = WindowManagerPipBackend(
          isMacOS: mac,
          isWindows: !mac,
          sizing: DesktopWindowSizing(isWindows: !mac, pixelRatio: () => 1),
        );
        final snapshot = await backend.capture();
        await backend.compact();
        await backend.rememberBounds();
        await backend.restore(snapshot);
        final sizes = calls
            .where((call) => call.method == 'setMinimumSize')
            .toList();
        expect((sizes.first.arguments as Map)['width'], 320);
        expect((sizes.last.arguments as Map)['width'], 800);
        final tops = calls
            .where((call) => call.method == 'setAlwaysOnTop')
            .toList();
        expect((tops.first.arguments as Map)['isAlwaysOnTop'], true);
        expect((tops.last.arguments as Map)['isAlwaysOnTop'], false);
        final bounds = calls
            .where((call) => call.method == 'setBounds')
            .toList();
        expect((bounds.last.arguments as Map)['width'], 1000);
        expect(
          calls
              .where((call) => call.method == 'setVisibleOnAllWorkspaces')
              .length,
          mac ? 2 : 0,
        );
        expect(
          (await SharedPreferences.getInstance()).getString(
            'desktop_pip_bounds_v1',
          ),
          isNotNull,
        );
        expect(
          calls.where((call) => call.method == 'setMaximizable').length,
          mac ? 0 : 1,
        );
        if (!mac) {
          expect(
            calls
                .where((call) => call.method == 'setMaximizable')
                .single
                .arguments,
            {'isMaximizable': true},
          );
        }
      },
    );
  }
}
