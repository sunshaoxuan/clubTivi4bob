import 'dart:async';

import 'package:clubtivi/features/player/prepared_channel_commit_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ready preview promotes immediately without reopening', () async {
    final gate = PreparedChannelCommitGate();
    var promotions = 0;
    expect(
      await gate.run(
        owner: Object(),
        onStart: () {},
        isCurrent: () => true,
        readyNow: () => true,
        waitUntilReady: () async => throw StateError('unexpected reopen'),
        promote: () async {
          promotions++;
          return true;
        },
      ),
      isTrue,
    );
    expect(promotions, 1);
  });

  test(
    'buffering preview waits and duplicate clicks share one commit',
    () async {
      final gate = PreparedChannelCommitGate();
      final owner = Object();
      final recovery = Completer<bool>();
      var starts = 0;
      var promotions = 0;
      Future<bool> commit() => gate.run(
        owner: owner,
        onStart: () => starts++,
        isCurrent: () => true,
        readyNow: () => false,
        waitUntilReady: () => recovery.future,
        promote: () async {
          promotions++;
          return true;
        },
      );
      final first = commit();
      final second = commit();
      expect(identical(first, second), isTrue);
      expect(starts, 1);
      expect(promotions, 0);
      recovery.complete(true);
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(promotions, 1);
    },
  );

  test(
    'failed recovery leaves promotion untouched for route fallback',
    () async {
      final gate = PreparedChannelCommitGate();
      var promoted = false;
      expect(
        await gate.run(
          owner: Object(),
          onStart: () {},
          isCurrent: () => true,
          readyNow: () => false,
          waitUntilReady: () async => false,
          promote: () async {
            promoted = true;
            return true;
          },
        ),
        isFalse,
      );
      expect(promoted, isFalse);
    },
  );

  test('new channel invalidates old waiting commit', () async {
    final gate = PreparedChannelCommitGate();
    final recovery = Completer<bool>();
    var generation = 0;
    var oldRequest = 0;
    var oldPromotions = 0;
    final old = gate.run(
      owner: Object(),
      onStart: () => oldRequest = ++generation,
      isCurrent: () => oldRequest == generation,
      readyNow: () => false,
      waitUntilReady: () => recovery.future,
      promote: () async {
        oldPromotions++;
        return true;
      },
    );
    expect(
      await gate.run(
        owner: Object(),
        onStart: () => generation++,
        isCurrent: () => true,
        readyNow: () => true,
        waitUntilReady: () async => true,
        promote: () async => true,
      ),
      isTrue,
    );
    recovery.complete(true);
    expect(await old, isFalse);
    expect(oldPromotions, 0);
  });

  test('promotion errors release gate so same preview can retry', () async {
    final gate = PreparedChannelCommitGate();
    final owner = Object();
    Future<bool> commit(bool fail) => gate.run(
      owner: owner,
      onStart: () {},
      isCurrent: () => true,
      readyNow: () => true,
      waitUntilReady: () async => true,
      promote: () async {
        if (fail) throw StateError('transient promotion failure');
        return true;
      },
    );
    await expectLater(commit(true), throwsStateError);
    expect(await commit(false), isTrue);
  });

  test('expired preview cannot wait or promote', () async {
    final gate = PreparedChannelCommitGate();
    expect(
      await gate.run(
        owner: Object(),
        onStart: () {},
        isCurrent: () => false,
        readyNow: () => throw StateError('unexpected state check'),
        waitUntilReady: () async => throw StateError('unexpected wait'),
        promote: () async => throw StateError('unexpected promotion'),
      ),
      isFalse,
    );
  });
}
