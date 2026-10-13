import 'dart:async';
import 'dart:io';

import 'package:clubtivi/app/android_app_controls.dart';
import 'package:clubtivi/core/android_app_exit.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('exit is single-flight and closes only after cleanup', () async {
    final ready = Completer<void>();
    final events = <String>[];
    final controller = AndroidAppExitController(
      prepare: () async {
        events.add('cleanup');
        await ready.future;
      },
      closeTask: () async => events.add('close'),
    );
    addTearDown(controller.dispose);
    final first = controller.requestExit();
    expect(controller.requestExit(), same(first));
    expect(controller.closing.value, isTrue);
    expect(events, ['cleanup']);
    ready.complete();
    await first;
    await controller.requestExit();
    expect(events, ['cleanup', 'close']);
  });

  test(
    'failed native exit retries without restarting disposed services',
    () async {
      var cleanups = 0;
      var attempts = 0;
      final controller = AndroidAppExitController(
        prepare: () async => cleanups++,
        closeTask: () async {
          if (++attempts == 1) throw StateError('close failed');
        },
      );
      addTearDown(controller.dispose);
      await controller.requestExit();
      expect(controller.error.value, '退出未完成，请重试。');
      expect(controller.closing.value, isTrue);
      await controller.requestExit();
      expect(cleanups, 1);
      expect(attempts, 2);
      expect(controller.error.value, isNull);
    },
  );

  test('cleanup failure does not prevent the user from exiting', () async {
    var closes = 0;
    final controller = AndroidAppExitController(
      prepare: () async => throw StateError('cleanup failed'),
      closeTask: () async => closes++,
    );
    addTearDown(controller.dispose);
    await controller.requestExit();
    expect(closes, 1);
    expect(controller.error.value, isNull);
  });

  test('native Android close requests task removal', () async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('bobtv/app');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await AndroidAppExitController.closeAndroidTask();
    expect(calls.map((call) => call.method), ['exit']);
  });

  test(
    'missing native extension falls back to Flutter activity close',
    () async {
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await AndroidAppExitController.closeAndroidTask();
      expect(calls, ['SystemNavigator.pop']);
    },
  );

  test('route-owned decoder disposal completes before exit drains', () async {
    final first = Completer<void>();
    final second = Completer<void>();
    AndroidExitDrain.track(first.future);
    AndroidExitDrain.track(second.future);
    var drained = false;
    final wait = AndroidExitDrain.wait().then((_) => drained = true);
    first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    second.completeError(StateError('decoder already closed'));
    await wait;
    expect(drained, isTrue);
    await AndroidExitDrain.wait();
  });

  test(
    'main player disposal is idempotent without initializing a decoder',
    () async {
      final player = PlayerService();
      final first = player.dispose();
      expect(player.dispose(), same(first));
      await first;
      await player.dispose();
    },
  );

  for (final entry in {
    '初始化': const Size(360, 640),
    '空频道': const Size(600, 960),
    '简洁竖屏': const Size(600, 960),
    '简洁横屏': const Size(1280, 800),
    '进阶': const Size(1024, 768),
    '设置': const Size(360, 640),
    '全屏播放': const Size(1920, 1080),
    '多画面': const Size(1280, 800),
    'Android TV': const Size(1920, 1080),
  }.entries) {
    testWidgets(
      '${entry.key} retains touch-sized exit without covering content',
      (tester) async {
        tester.view.physicalSize = entry.value;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final prepared = Completer<void>();
        var closes = 0;
        final controller = AndroidAppExitController(
          prepare: () => prepared.future,
          closeTask: () async => closes++,
        );
        final pip = ValueNotifier(false);
        addTearDown(controller.dispose);
        addTearDown(pip.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: AndroidAppControls(
              enabled: true,
              controller: controller,
              pictureInPicture: pip,
              child: const ColoredBox(
                key: ValueKey('route'),
                color: Colors.black,
              ),
            ),
          ),
        );
        final exit = find.byKey(const ValueKey('android-app-exit'));
        expect(exit, findsOneWidget);
        expect(tester.getSize(exit).height, greaterThanOrEqualTo(48));
        expect(
          tester.getRect(find.byKey(const ValueKey('route'))).top,
          greaterThanOrEqualTo(tester.getRect(exit).bottom),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(exit);
        await tester.pump();
        expect(find.text('正在退出 BobTV…'), findsOneWidget);
        expect(find.byKey(const ValueKey('route')), findsNothing);
        expect(closes, 0);
        prepared.complete();
        await tester.pump();
        expect(closes, 1);
      },
    );
  }

  testWidgets('native PiP keeps all available space for the video', (
    tester,
  ) async {
    final controller = AndroidAppExitController(
      prepare: () async {},
      closeTask: () async {},
    );
    final pip = ValueNotifier(false);
    addTearDown(controller.dispose);
    addTearDown(pip.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AndroidAppControls(
          enabled: true,
          controller: controller,
          pictureInPicture: pip,
          child: const ColoredBox(key: ValueKey('video'), color: Colors.black),
        ),
      ),
    );
    pip.value = true;
    await tester.pump();
    expect(find.byKey(const ValueKey('android-app-exit')), findsNothing);
    expect(tester.getRect(find.byKey(const ValueKey('video'))).top, 0);
    pip.value = false;
    await tester.pump();
    expect(find.byKey(const ValueKey('android-app-exit')), findsOneWidget);
  });

  testWidgets('desktop layout remains completely unchanged', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AndroidAppControls(
          enabled: false,
          child: ColoredBox(key: ValueKey('desktop'), color: Colors.black),
        ),
      ),
    );
    expect(find.text('退出 BobTV'), findsNothing);
    expect(tester.getRect(find.byKey(const ValueKey('desktop'))).top, 0);
  });

  testWidgets(
    'real exit detaches routes and disposes providers before native close',
    (tester) async {
      final events = <String>[];
      final alive = Provider<int>((ref) {
        ref.onDispose(() => events.add('providers'));
        return 1;
      });
      final pip = ValueNotifier(false);
      addTearDown(pip.dispose);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('bobtv/app');
      messenger.setMockMethodCallHandler(channel, (call) async {
        events.add('native');
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: AndroidAppControls(
              enabled: true,
              pictureInPicture: pip,
              child: Consumer(
                builder: (context, ref, _) => Text('live ${ref.watch(alive)}'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('android-app-exit')));
      await tester.pump();
      await tester.pump();
      expect(find.text('live 1'), findsNothing);
      expect(find.text('正在退出 BobTV…'), findsOneWidget);
      expect(events, ['providers', 'native']);
      expect(tester.takeException(), isNull);
    },
  );

  test('Android close is global and removes the task without force-crashing', () {
    final app = File('lib/app/app.dart').readAsStringSync();
    final native = File(
      'android/app/src/main/kotlin/io/github/clubanderson/clubtivi/MainActivity.kt',
    ).readAsStringSync();
    final controls = File(
      'lib/app/android_app_controls.dart',
    ).readAsStringSync();
    expect(app, contains('return AndroidAppControls('));
    expect(native, contains('"bobtv/app"'));
    expect(native, contains('finishAndRemoveTask()'));
    expect(native, isNot(contains('killProcess(')));
    expect(controls, contains('container.exists(playerServiceProvider)'));
    expect(controls, contains('AndroidUpdateService.instance.stop'));
    expect(controls, contains('container.dispose()'));
    expect(controls, isNot(contains('exit(0)')));
  });
}
