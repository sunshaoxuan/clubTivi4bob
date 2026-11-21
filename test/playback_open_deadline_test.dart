import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/features/player/playback_open_deadline.dart';

void main() {
  test('subtitle preparation may finish after the ordinary route deadline', () {
    fakeAsync((time) {
      final opening = Completer<void>();
      var completed = false;
      Object? error;
      awaitPlaybackOpen(
        opening.future,
        initialTimeout: const Duration(seconds: 5),
        preparingSubtitleClock: () => true,
      ).then((_) => completed = true, onError: (Object e) => error = e);
      time.elapse(const Duration(seconds: 6));
      expect(completed, isFalse);
      expect(error, isNull);
      opening.complete();
      time.flushMicrotasks();
      expect(completed, isTrue);
      expect(error, isNull);
    });
  });

  test('ordinary or superseded routes retain the five-second deadline', () {
    fakeAsync((time) {
      var current = true;
      final errors = <Object>[];
      for (final clock in [() => false, () => current]) {
        awaitPlaybackOpen(
          Completer<void>().future,
          initialTimeout: const Duration(seconds: 5),
          preparingSubtitleClock: clock,
        ).catchError((Object e) {
          errors.add(e);
        });
      }
      time.elapse(const Duration(seconds: 4));
      current = false;
      time.elapse(const Duration(seconds: 1));
      expect(errors, hasLength(2));
      expect(errors, everyElement(isA<TimeoutException>()));
    });
  });

  test('all subtitle startup waits stop at the same total bound', () {
    fakeAsync((time) {
      final errors = <Object>[];
      for (final initial in [5, 35]) {
        awaitPlaybackOpen(
          Completer<void>().future,
          initialTimeout: Duration(seconds: initial),
          preparingSubtitleClock: () => true,
        ).catchError((Object e) {
          errors.add(e);
        });
      }
      time.elapse(const Duration(seconds: 34));
      expect(errors, isEmpty);
      time.elapse(const Duration(seconds: 1));
      expect(errors, hasLength(2));
    });
  });
}
