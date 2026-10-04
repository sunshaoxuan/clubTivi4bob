import 'package:clubtivi/app/windows_fullscreen_controls.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          call,
        ) async {
          calls.add(call);
          return call.method == 'isFullScreen' ? true : null;
        });
  });
  tearDown(() {
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
    await tester.pumpWidget(const SizedBox());
  });
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
}
