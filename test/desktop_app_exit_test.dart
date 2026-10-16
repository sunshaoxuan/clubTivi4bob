import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:clubtivi/app/desktop_app_lifecycle.dart';
import 'package:clubtivi/core/desktop_app_exit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'renderer detach completes without warmup when frames are active',
    () async {
      var warmups = 0;
      await detachDesktopRenderers(
        endOfFrame: () async {},
        warmUpFrame: () => warmups++,
      );
      expect(warmups, 0);
    },
  );

  test('renderer detach requests a bounded warmup when vsync stops', () async {
    final frame = Completer<void>();
    var warmups = 0;
    await detachDesktopRenderers(
      endOfFrame: () => frame.future,
      warmUpFrame: () {
        warmups++;
        frame.complete();
      },
      timeout: Duration.zero,
    );
    expect(warmups, 1);
  });

  test(
    'missing warmup acknowledgement never grants renderer detachment',
    () async {
      final frame = Completer<void>();
      await expectLater(
        detachDesktopRenderers(
          endOfFrame: () => frame.future,
          warmUpFrame: () {},
          timeout: Duration.zero,
        ),
        throwsA(isA<TimeoutException>()),
      );
      frame.complete();
    },
  );

  test('close cannot run before cleanup acknowledgement', () async {
    final ready = Completer<void>();
    final order = <String>[];
    final controller = DesktopAppExitController(
      prepare: () async {
        order.add('prepare');
        await ready.future;
        order.add('clean');
      },
      closeNative: () async {
        order.add('close');
      },
    );
    final request = controller.requestExit('fixture');
    expect(order, ['prepare']);
    final duplicate = controller.requestExit('duplicate');
    expect(identical(request, duplicate), isTrue);
    ready.complete();
    await request;
    expect(order, ['prepare', 'clean', 'close']);
    controller.dispose();
  });

  test(
    'platform reentry shares preparation without awaiting native close',
    () async {
      var calls = 0;
      late DesktopAppExitController controller;
      controller = DesktopAppExitController(
        prepare: () async {
          calls++;
        },
        closeNative: () async {
          await controller.prepareExit('platform_reentry');
        },
      );
      await controller
          .requestExit('fixture')
          .timeout(const Duration(seconds: 1));
      expect(calls, 1);
      controller.dispose();
    },
  );

  test('cleanup failure keeps engine alive and supports retry', () async {
    var failures = true;
    var closed = false;
    final controller = DesktopAppExitController(
      prepare: () async {
        if (failures) throw StateError('fixture');
      },
      closeNative: () async {
        closed = true;
      },
    );
    await expectLater(controller.requestExit('fixture'), throwsStateError);
    expect(closed, isFalse);
    expect(controller.prepared, isFalse);
    expect(controller.error.value, isNotNull);
    failures = false;
    await controller.requestExit('retry');
    expect(closed, isTrue);
    controller.dispose();
  });

  testWidgets('idle lifecycle changes never request close', (tester) async {
    var closes = 0;
    final controller = DesktopAppExitController(
      prepare: () async {},
      closeNative: () async {
        closes++;
      },
    );
    await tester.pumpWidget(
      DesktopAppLifecycle(
        enabled: true,
        controller: controller,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('playing'),
        ),
      ),
    );
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    await tester.pump(const Duration(minutes: 10));
    expect(closes, 0);
    expect(controller.closing.value, isFalse);
    expect(find.text('playing'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('exit screen detaches route before preparation completes', (
    tester,
  ) async {
    final ready = Completer<void>();
    final controller = DesktopAppExitController(
      prepare: () => ready.future,
      closeNative: () async {},
    );
    await tester.pumpWidget(
      DesktopAppLifecycle(
        enabled: true,
        controller: controller,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('decoder route'),
        ),
      ),
    );
    final request = controller.requestExit('fixture');
    await tester.pump();
    expect(find.text('decoder route'), findsNothing);
    expect(find.text('正在清理播放器并退出…'), findsOneWidget);
    ready.complete();
    await request;
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('platform exit releases native close veto after cleanup', (
    tester,
  ) async {
    const channel = MethodChannel('window_manager');
    final closeVetoes = <bool>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'setPreventClose') {
        closeVetoes.add((call.arguments as Map)['isPreventClose'] as bool);
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      const ProviderScope(
        child: DesktopAppLifecycle(
          enabled: true,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Text('playing'),
          ),
        ),
      ),
    );
    final dynamic host = tester.state(find.byType(DesktopAppLifecycle));
    final Future<AppExitResponse> exit = host.didRequestAppExit();
    await tester.pump();
    await tester.pump();
    expect(await exit, AppExitResponse.exit);
    expect(closeVetoes, [true, false]);
    await tester.pumpWidget(const SizedBox());
  });
}
