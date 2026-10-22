import 'dart:async';

import 'package:clubtivi/core/desktop_window_pin.dart';
import 'package:clubtivi/features/player/desktop_window_pin_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Backend implements WindowPinBackend {
  bool fullscreen = false;
  bool top = false;
  bool ignoreWrites = false;
  bool failWrites = false;
  Completer<void>? writeGate;
  final writes = <bool>[];
  @override
  Future<bool> isFullscreen() async => fullscreen;
  @override
  Future<bool> isAlwaysOnTop() async => top;
  @override
  Future<void> setAlwaysOnTop(bool value) async {
    writes.add(value);
    await writeGate?.future;
    if (failWrites) throw StateError('fixture pin failed');
    if (!ignoreWrites) top = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pin changes are verified and apply until explicitly cancelled',
    () async {
      final backend = _Backend();
      final pin = DesktopWindowPin(backend: backend);
      addTearDown(pin.dispose);
      expect(pin.pinned, isFalse);
      expect(backend.writes, isEmpty);
      expect(pin.restoreValue(true), isTrue);
      await pin.toggle();
      expect(backend.writes, [true]);
      expect(pin.pinned, isTrue);
      expect(pin.restoreValue(false), isTrue);
      await pin.toggle();
      expect(backend.writes, [true, false]);
      expect(pin.pinned, isFalse);
      expect(pin.restoreValue(true), isFalse);
    },
  );

  test('native fullscreen is not changed by a pin request', () async {
    final backend = _Backend()..fullscreen = true;
    final pin = DesktopWindowPin(backend: backend);
    addTearDown(pin.dispose);
    await expectLater(
      pin.toggle(),
      throwsA(isA<WindowPinRequiresWindowMode>()),
    );
    expect(backend.writes, isEmpty);
    expect(pin.pinned, isFalse);
    expect(pin.busy, isFalse);
  });

  test(
    'failed or unverified writes roll back without a false pinned state',
    () async {
      for (final throws in [false, true]) {
        final backend = _Backend()
          ..failWrites = throws
          ..ignoreWrites = !throws;
        final pin = DesktopWindowPin(backend: backend);
        await expectLater(pin.toggle(), throwsStateError);
        expect(backend.writes, [true, false]);
        expect(pin.pinned, isFalse);
        expect(pin.restoreValue(true), isTrue);
        expect(pin.canToggle, isTrue);
        backend.failWrites = false;
        backend.ignoreWrites = false;
        await pin.toggle();
        expect(pin.pinned, isTrue);
        pin.dispose();
      }
    },
  );

  test(
    'rapid requests share one write and presentation waits for it',
    () async {
      final backend = _Backend()..writeGate = Completer<void>();
      final pin = DesktopWindowPin(backend: backend);
      addTearDown(pin.dispose);
      final first = pin.toggle();
      final duplicate = pin.toggle();
      expect(identical(first, duplicate), isTrue);
      final release = pin.lockForPresentation();
      var idle = false;
      final waiting = pin.idle.then((_) => idle = true);
      await Future<void>.delayed(Duration.zero);
      expect(backend.writes, [true]);
      expect(idle, isFalse);
      backend.writeGate!.complete();
      await Future.wait([first, duplicate, waiting]);
      expect(pin.pinned, isTrue);
      expect(pin.canToggle, isFalse);
      await pin.toggle();
      expect(backend.writes, [true]);
      release();
      release();
      expect(pin.canToggle, isTrue);
    },
  );

  test('nested fullscreen and PiP locks cannot release one another', () async {
    final backend = _Backend();
    final pin = DesktopWindowPin(backend: backend);
    addTearDown(pin.dispose);
    final fullscreen = pin.lockForPresentation();
    final pip = pin.lockForPresentation();
    fullscreen();
    expect(pin.canToggle, isFalse);
    await pin.toggle();
    expect(backend.writes, isEmpty);
    pip();
    expect(pin.canToggle, isTrue);
  });

  test(
    'native fullscreen exit restores the pin only after presentation releases it',
    () async {
      final backend = _Backend();
      final pin = DesktopWindowPin(backend: backend);
      addTearDown(pin.dispose);
      await pin.toggle();
      backend.top = false;
      final release = pin.lockForPresentation();
      pin.onWindowLeaveFullScreen();
      await pin.idle;
      expect(backend.writes, [true]);
      release();
      pin.onWindowLeaveFullScreen();
      await pin.idle;
      expect(backend.writes, [true, true]);
      expect(pin.pinned, isTrue);
      backend.fullscreen = true;
      backend.top = false;
      pin.onWindowFocus();
      await pin.idle;
      expect(backend.writes, [true, true]);
    },
  );

  test(
    'native focus repairs a stale level without moving or focusing the window',
    () async {
      final backend = _Backend();
      final pin = DesktopWindowPin(backend: backend);
      addTearDown(pin.dispose);
      await pin.toggle();
      await pin.toggle();
      backend.top = true;
      pin.onWindowFocus();
      await pin.idle;
      expect(backend.writes, [true, false, false]);
      expect(pin.pinned, isFalse);
    },
  );

  test('native bridge uses only window-level getters and setter', () async {
    final calls = <MethodCall>[];
    var top = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'isFullScreen') return false;
      if (call.method == 'isAlwaysOnTop') return top;
      if (call.method == 'setAlwaysOnTop') {
        top = (call.arguments as Map)['isAlwaysOnTop'] as bool;
        return null;
      }
      fail('Unexpected native operation: ${call.method}');
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      ),
    );
    final pin = DesktopWindowPin();
    addTearDown(pin.dispose);
    await pin.toggle();
    expect(top, isTrue);
    expect(calls.map((call) => call.method), [
      'isFullScreen',
      'isAlwaysOnTop',
      'setAlwaysOnTop',
      'isAlwaysOnTop',
    ]);
  });

  testWidgets('both views show the same pin state and can cancel it', (
    tester,
  ) async {
    final backend = _Backend();
    final pin = DesktopWindowPin(backend: backend);
    addTearDown(pin.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              DesktopWindowPinButton(controller: pin),
              DesktopWindowPinButton(controller: pin, compact: true),
            ],
          ),
        ),
      ),
    );
    expect(find.byTooltip('窗口置顶'), findsNWidgets(2));
    await tester.tap(find.byTooltip('窗口置顶').first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消置顶'), findsNWidgets(2));
    expect(find.byIcon(Icons.push_pin_rounded), findsNWidgets(2));
    expect(
      tester
          .widgetList<Semantics>(find.byType(Semantics))
          .where((widget) => widget.properties.toggled == true),
      hasLength(2),
    );
    await tester.tap(find.byTooltip('取消置顶').last);
    await tester.pumpAndSettle();
    expect(find.byTooltip('窗口置顶'), findsNWidgets(2));
    expect(backend.writes, [true, false]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an unsuccessful pin remains unselected and reports failure', (
    tester,
  ) async {
    final pin = DesktopWindowPin(backend: _Backend()..ignoreWrites = true);
    addTearDown(pin.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DesktopWindowPinButton(controller: pin)),
      ),
    );
    await tester.tap(find.byTooltip('窗口置顶'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消置顶'), findsNothing);
    expect(find.text('窗口置顶切换失败，请重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
