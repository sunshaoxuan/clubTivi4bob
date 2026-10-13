import 'dart:async';

import 'package:clubtivi/features/player/mobile_fullscreen_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Android repeated fullscreen and back restore system UI in order',
    () async {
      final modes = <SystemUiMode>[];
      for (var cycle = 0; cycle < 8; cycle++) {
        final session = MobileFullscreenSession(
          setMode: (mode) async => modes.add(mode),
        );
        await session.enter();
        await session.exit();
        await session.exit();
        await session.enter();
      }
      expect(modes, [
        for (var i = 0; i < 8; i++) ...[
          SystemUiMode.immersiveSticky,
          SystemUiMode.edgeToEdge,
        ],
      ]);
    },
  );

  test(
    'Android Back during entry drains entry before restoring bars',
    () async {
      final gate = Completer<void>();
      final modes = <SystemUiMode>[];
      final session = MobileFullscreenSession(
        setMode: (mode) async {
          modes.add(mode);
          if (mode == SystemUiMode.immersiveSticky) await gate.future;
        },
      );
      final entering = session.enter();
      final leaving = session.exit();
      expect(identical(leaving, session.exit()), isTrue);
      expect(modes, [SystemUiMode.immersiveSticky]);
      gate.complete();
      await Future.wait([entering, leaving]);
      expect(modes, [SystemUiMode.immersiveSticky, SystemUiMode.edgeToEdge]);
    },
  );

  test('Android failed entry still restores bars on Back', () async {
    final modes = <SystemUiMode>[];
    final session = MobileFullscreenSession(
      setMode: (mode) async {
        modes.add(mode);
        if (mode == SystemUiMode.immersiveSticky) {
          throw StateError('entry failed');
        }
      },
    );
    await expectLater(session.enter(), throwsStateError);
    await session.exit();
    expect(modes.last, SystemUiMode.edgeToEdge);
  });

  test(
    'Android failed restoration can retry without re-entering fullscreen',
    () async {
      var restores = 0;
      final session = MobileFullscreenSession(
        setMode: (mode) async {
          if (mode == SystemUiMode.edgeToEdge && ++restores == 1) {
            throw StateError('transient failure');
          }
        },
      );
      await session.enter();
      await expectLater(session.exit(), throwsStateError);
      await session.exit();
      expect(restores, 2);
    },
  );

  test(
    'Android default backend sends the actual SystemChrome mode calls',
    () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      for (var cycle = 0; cycle < 3; cycle++) {
        final session = MobileFullscreenSession();
        await session.enter();
        await session.exit();
      }
      expect(
        calls.map((c) => c.method),
        everyElement('SystemChrome.setEnabledSystemUIMode'),
      );
      expect(calls.map((c) => c.arguments), [
        for (var i = 0; i < 3; i++) ...[
          'SystemUiMode.immersiveSticky',
          'SystemUiMode.edgeToEdge',
        ],
      ]);
    },
  );
}
