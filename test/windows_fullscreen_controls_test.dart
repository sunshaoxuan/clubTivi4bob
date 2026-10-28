import 'dart:async';

import 'package:clubtivi/app/windows_fullscreen_controls.dart';
import 'package:clubtivi/features/player/desktop_fullscreen_session.dart';
import 'package:clubtivi/core/desktop_window_pin.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _WindowBackend implements FullscreenWindowBackend {
  final changes = StreamController<bool>.broadcast();
  @override
  Stream<bool> get fullscreenChanges => changes.stream;
  @override
  Future<FullscreenWindowSnapshot> capture() async =>
      const FullscreenWindowSnapshot(
        bounds: Rect.fromLTWH(30, 30, 1000, 650),
        maximized: false,
        alwaysOnTop: false,
      );
  @override
  Future<bool> isFullscreen() async => true;
  @override
  Future<void> prepareEntry() async {}
  @override
  Future<void> restore(FullscreenWindowSnapshot snapshot) async {}
  @override
  Future<void> setFullscreen(bool value) async {}
  @override
  void dispose() => unawaited(changes.close());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  var fullscreen = true;
  setUp(() {
    calls.clear();
    fullscreen = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('bobtv/window_chrome'),
          (_) async => null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          call,
        ) async {
          calls.add(call);
          if (call.method == 'setFullScreen') {
            fullscreen = (call.arguments as Map)['isFullScreen'] as bool;
          }
          return call.method == 'isFullScreen' ? fullscreen : null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('bobtv/window_chrome'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });
  testWidgets(
    'Top edge reveals controls after hiding, and native close works',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: WindowsFullscreenControls(
            enabled: true,
            child: Scaffold(body: Text('频道页面')),
          ),
        ),
      );
      await tester.pump();
      expect(find.byTooltip('关闭 BobTV'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.byTooltip('关闭 BobTV'), findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(300, 100));
      await mouse.moveTo(const Offset(300, 3));
      await tester.pump();
      expect(find.byTooltip('关闭 BobTV'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭 BobTV'));
      await tester.pump();
      expect(calls.where((call) => call.method == 'close').length, 1);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('Restore exits native fullscreen, without closing the app', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: WindowsFullscreenControls(enabled: true, child: Scaffold()),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('恢复窗口'));
    await tester.pump();
    expect(
      calls.any(
        (call) =>
            call.method == 'setFullScreen' &&
            (call.arguments as Map)['isFullScreen'] == false,
      ),
      isTrue,
    );
    expect(calls.any((call) => call.method == 'close'), isFalse);
    expect(
      calls.where((call) => call.method == 'setMaximizable').single.arguments,
      {'isMaximizable': true},
    );
    expect(
      calls.where((call) => call.method == 'setResizable').single.arguments,
      {'isResizable': true},
    );
    expect(find.byTooltip('恢复窗口'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Restore first completes the owning video route', (tester) async {
    var returned = false;
    late DesktopFullscreenSession session;
    session = DesktopFullscreenSession(
      backend: _WindowBackend(),
      onChanged: (_) {},
      onExternalExit: () {},
      onWindowRestore: () async {
        await session.exit(forceWindowed: true);
        returned = true;
        fullscreen = false;
        return true;
      },
    );
    await session.enter();
    await tester.pumpWidget(
      const MaterialApp(
        home: WindowsFullscreenControls(enabled: true, child: Scaffold()),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('恢复窗口'));
    await tester.pump();

    expect(returned, isTrue);
    expect(calls.any((call) => call.method == 'setFullScreen'), isFalse);
    expect(find.byTooltip('恢复窗口'), findsNothing);
    session.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Moving from top edge toward buttons keeps controls visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: WindowsFullscreenControls(enabled: true, child: Scaffold()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(730, 100));
    await mouse.moveTo(const Offset(730, 2));
    await tester.pump();
    await mouse.moveTo(const Offset(730, 48));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byTooltip('恢复窗口'), findsOneWidget);
    await mouse.moveTo(tester.getCenter(find.byTooltip('恢复窗口')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byTooltip('恢复窗口'), findsOneWidget);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('A busy video owner cannot trigger a second native exit', (
    tester,
  ) async {
    final session = DesktopFullscreenSession(
      backend: _WindowBackend(),
      onChanged: (_) {},
      onExternalExit: () {},
      onWindowRestore: () async => false,
    );
    await session.enter();
    await tester.pumpWidget(
      const MaterialApp(
        home: WindowsFullscreenControls(enabled: true, child: Scaffold()),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('恢复窗口'));
    await tester.pump();
    expect(calls.any((call) => call.method == 'setFullScreen'), isFalse);
    session.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Resize discovers fullscreen when native enter event is missing',
    (tester) async {
      fullscreen = false;
      await tester.pumpWidget(
        const MaterialApp(
          home: WindowsFullscreenControls(enabled: true, child: Scaffold()),
        ),
      );
      await tester.pump();
      expect(find.byTooltip('关闭 BobTV'), findsNothing);
      fullscreen = true;
      final dynamic state = tester.state(
        find.byType(WindowsFullscreenControls),
      );
      state.onWindowResize();
      await tester.pumpAndSettle();
      expect(find.byTooltip('恢复窗口'), findsOneWidget);
      fullscreen = false;
      state.onWindowFocus();
      await tester.pumpAndSettle();
      expect(find.byTooltip('恢复窗口'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('Native Mac chrome is left untouched', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: WindowsFullscreenControls(enabled: false, child: Text('原生窗口')),
      ),
    );
    expect(find.text('原生窗口'), findsOneWidget);
    expect(find.byTooltip('关闭 BobTV'), findsNothing);
    expect(calls, isEmpty);
  });

  testWidgets('native restore preserves the explicit window pin', (
    tester,
  ) async {
    var top = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'isFullScreen') return fullscreen;
      if (call.method == 'isAlwaysOnTop') return top;
      if (call.method == 'setAlwaysOnTop') {
        top = (call.arguments as Map)['isAlwaysOnTop'] as bool;
      }
      if (call.method == 'setFullScreen') {
        fullscreen = (call.arguments as Map)['isFullScreen'] as bool;
      }
      return null;
    });
    fullscreen = false;
    final pin = DesktopWindowPin();
    addTearDown(pin.dispose);
    await pin.toggle();
    fullscreen = true;
    calls.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: WindowsFullscreenControls(
          enabled: true,
          pinning: pin,
          child: const Scaffold(),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('恢复窗口'));
    await tester.pumpAndSettle();
    expect(fullscreen, isFalse);
    expect(top, isTrue);
    expect(pin.pinned, isTrue);
    expect(
      calls.where((call) => call.method == 'setAlwaysOnTop').single.arguments,
      {'isAlwaysOnTop': true},
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
