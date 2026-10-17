import 'dart:async';
import 'dart:io';

import 'package:clubtivi/features/player/prepared_channel_commit_gate.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('UI commits preview before route sync or a scheduled frame', () {
    final source = File(
      'lib/features/channels/channels_screen.dart',
    ).readAsStringSync();
    final selection = source.substring(
      source.indexOf('  Future<void> _selectChannel('),
    );
    final start = selection.indexOf('    if (commitPreview) {');
      final end = selection.indexOf('    // Cold selection may build', start);
    final fastPath = selection.substring(start, end);
    expect(start, greaterThan(0));
    expect(fastPath, contains('commitPreparedChannel(channel.id)'));
    expect(fastPath, isNot(contains('routeStates')));
    expect(fastPath, isNot(contains('switchChannel(')));
    expect(fastPath, isNot(contains('.play(')));
      expect(fastPath, isNot(contains('endOfFrame')));
    expect(fastPath, contains('return;'));
    expect(
      selection.indexOf('await WidgetsBinding.instance.endOfFrame'),
        greaterThan(end),
    );
    expect(selection, isNot(contains('if (commitPreview && !switched')));
  });

  test(
    'verified preview transfer never polls buffering or media readiness',
    () {
      final source = File(
        'lib/features/player/player_service.dart',
      ).readAsStringSync();
      final commit = source.substring(
        source.indexOf('  Future<bool> commitPreparedChannel('),
        source.indexOf('  Future<bool> _waitForPreparedChannel('),
      );
      expect(commit, isNot(contains('_waitForPreparedChannel(')));
      expect(commit, isNot(contains('preparedMediaReady(')));
      expect(commit, isNot(contains('state.buffering')));
      expect(commit, isNot(contains('Future<void>.delayed')));
      expect(commit, isNot(contains('.open(')));
      expect(commit, contains('prepared.player,'));
      expect(commit, contains('prepared.controller,'));
      expect(commit, contains('_routeAllowed(prepared.url)'));
      expect(commit, contains('request == _channelSwitchGeneration'));
    },
  );

  test('verified preview promotion begins synchronously with no timer', () {
    fakeAsync((clock) {
      final gate = PreparedChannelCommitGate();
      bool? result;
      var promotions = 0;
      gate
          .run(
            owner: Object(),
            onStart: () {},
            isCurrent: () => true,
            promote: () async {
              promotions++;
              return true;
            },
          )
          .then((value) => result = value);
      expect(promotions, 1);
      expect(clock.pendingTimers, isEmpty);
      clock.flushMicrotasks();
      expect(result, isTrue);
      expect(clock.elapsed, Duration.zero);
    });
  });

  test(
    'native handoff is the only pending operation and clicks coalesce',
    () async {
      final gate = PreparedChannelCommitGate();
      final owner = Object();
      final handoff = Completer<bool>();
      var starts = 0;
      var promotions = 0;
      Future<bool> commit() => gate.run(
        owner: owner,
        onStart: () => starts++,
        isCurrent: () => true,
        promote: () {
          promotions++;
          return handoff.future;
        },
      );
      final first = commit();
      final second = commit();
      expect(identical(first, second), isTrue);
      expect(starts, 1);
      expect(promotions, 1);
      handoff.complete(true);
      expect(await first, isTrue);
      expect(await second, isTrue);
    },
  );

  test(
    'existing decoder and controller ownership is transferred unchanged',
    () async {
      final gate = PreparedChannelCommitGate();
      final decoder = Object();
      final controller = Object();
      final preview = (decoder: decoder, controller: controller);
      Object? activeDecoder;
      Object? activeController;
      expect(
        await gate.run(
          owner: preview,
          onStart: () {},
          isCurrent: () => true,
          promote: () async {
            activeDecoder = preview.decoder;
            activeController = preview.controller;
            return true;
          },
        ),
        isTrue,
      );
      expect(identical(activeDecoder, decoder), isTrue);
      expect(identical(activeController, controller), isTrue);
    },
  );

  test(
    'new selection invalidates an older asynchronous native handoff',
    () async {
      final gate = PreparedChannelCommitGate();
      final oldHandoff = Completer<void>();
      var generation = 0;
      var oldRequest = 0;
      var oldPromotions = 0;
      final old = gate.run(
        owner: Object(),
        onStart: () => oldRequest = ++generation,
        isCurrent: () => oldRequest == generation,
        promote: () async {
          await oldHandoff.future;
          if (oldRequest != generation) return false;
          oldPromotions++;
          return true;
        },
      );
      expect(
        await gate.run(
          owner: Object(),
          onStart: () => generation++,
          isCurrent: () => true,
          promote: () async => true,
        ),
        isTrue,
      );
      oldHandoff.complete();
      expect(await old, isFalse);
      expect(oldPromotions, 0);
    },
  );

  test('native promotion errors release the gate for a retry', () async {
    final gate = PreparedChannelCommitGate();
    final owner = Object();
    Future<bool> commit(bool fail) => gate.run(
      owner: owner,
      onStart: () {},
      isCurrent: () => true,
      promote: () async {
        if (fail) throw StateError('native promotion failure');
        return true;
      },
    );
    await expectLater(commit(true), throwsStateError);
    expect(await commit(false), isTrue);
  });

  test('cancelled or retired preview cannot replace active playback', () async {
    final gate = PreparedChannelCommitGate();
    expect(
      await gate.run(
        owner: Object(),
        onStart: () {},
        isCurrent: () => false,
        promote: () async => throw StateError('unexpected promotion'),
      ),
      isFalse,
    );
  });
}
