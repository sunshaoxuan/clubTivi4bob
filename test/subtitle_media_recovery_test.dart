import 'dart:async';

import 'package:clubtivi/features/player/subtitle_media_recovery.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only starts after position advances on the recovered route', () {
    fakeAsync((clock) {
      var buffering = true;
      var playing = true;
      var position = Duration.zero;
      var attempts = 0;
      final recovery = SubtitleMediaRecovery(
        sample: () =>
            (playing: playing, buffering: buffering, position: position),
        enabled: () => true,
        warm: () async {
          ++attempts;
          return true;
        },
      );
      void tick(int at) {
        position = Duration(seconds: at);
        clock.elapse(const Duration(seconds: 1));
      }

      recovery.start();
      tick(10);
      tick(11);
      expect(attempts, 0);
      buffering = false;
      playing = false;
      tick(13);
      expect(attempts, 0);
      playing = true;
      tick(14);
      tick(14); // stalled even if the buffering flag is clear
      tick(19); // discontinuity does not count as decoded progress
      tick(20);
      expect(attempts, 0);
      tick(21);
      expect(attempts, 1);
      clock.elapse(const Duration(minutes: 6));
      expect(attempts, 1);
    });
  });

  test('coalesces warmups and backs off after a failed candidate', () {
    fakeAsync((clock) {
      var position = Duration.zero;
      final pending = Completer<bool>();
      var attempts = 0;
      final recovery = SubtitleMediaRecovery(
        sample: () => (playing: true, buffering: false, position: position),
        enabled: () => true,
        warm: () => ++attempts == 1 ? pending.future : Future.value(false),
      );
      void tick() {
        position += const Duration(seconds: 1);
        clock.elapse(const Duration(seconds: 1));
      }

      recovery.start();
      for (var i = 0; i < 10; i++) {
        recovery.start();
        tick();
      }
      expect(attempts, 1);
      pending.complete(false);
      clock.flushMicrotasks();
      tick();
      tick();
      expect(attempts, 1);
      tick();
      expect(attempts, 2);
      for (var i = 0; i < 3; i++) {
        tick();
      }
      expect(attempts, 2);
      tick();
      expect(attempts, 3);
      recovery.cancel();
    });
  });

  test('disabling captions or switching routes stops the recovery', () {
    fakeAsync((clock) {
      var position = Duration.zero;
      var enabled = false;
      var attempts = 0;
      final pending = Completer<bool>();
      final recovery = SubtitleMediaRecovery(
        sample: () => (playing: true, buffering: false, position: position),
        enabled: () => enabled,
        warm: () {
          ++attempts;
          return pending.future;
        },
      );
      void advance() {
        for (var i = 0; i < 5; i++) {
          position += const Duration(seconds: 1);
          clock.elapse(const Duration(seconds: 1));
        }
      }

      recovery.start();
      advance();
      expect(attempts, 0);
      enabled = true;
      advance();
      expect(attempts, 1);
      recovery.cancel();
      pending.complete(false);
      clock.flushMicrotasks();
      advance();
      expect(attempts, 1);
    });
  });
}
