import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/features/player/client_audio_window.dart';

Uint8List samples(int count, int value) =>
    Int16List.fromList(List.filled(count, value)).buffer.asUint8List();

void main() {
  test('missed capture time stays silent without shifting later dialogue', () {
    final window = buildPcmWindow([
      (start: 10.0, bytes: samples(160, 123)),
      (start: 10.03, bytes: samples(160, 456)),
    ])!;
    final pcm = window.bytes.buffer.asInt16List();
    expect(window.end, closeTo(10.04, 1e-9));
    expect(window.gapSeconds, closeTo(.02, 1e-9));
    expect(pcm.take(160), everyElement(123));
    expect(pcm.skip(160).take(320), everyElement(0));
    expect(pcm.skip(480), everyElement(456));
  });

  test('overlapping taps do not duplicate already captured samples', () {
    final window = buildPcmWindow([
      (start: 20.0, bytes: samples(320, 123)),
      (start: 20.01, bytes: samples(320, 456)),
    ])!;
    expect(window.duration, closeTo(.03, 1e-9));
    expect(window.gapSeconds, 0);
    final pcm = window.bytes.buffer.asInt16List();
    expect(pcm.take(320), everyElement(123));
    expect(pcm.skip(320), everyElement(456));
  });

  test('unusable and unbounded native clocks are rejected', () {
    expect(buildPcmWindow([]), isNull);
    expect(
      () => buildPcmWindow([(start: double.nan, bytes: samples(1, 0))]),
      throwsFormatException,
    );
    expect(
      () => buildPcmWindow([
        (start: 0.0, bytes: samples(1, 0)),
        (start: 41.0, bytes: samples(1, 0)),
      ]),
      throwsFormatException,
    );
  });

  test('recognition slower than real time raises the playback reserve', () {
    final budget = SpeechPlaybackBudget();
    expect(budget.minimumSeconds(16, cold: true), 24);
    budget.record(16, 23.4);
    expect(budget.minimumSeconds(16, cold: false), 30);
    expect(budget.minimumSeconds(8, cold: false), closeTo(16.625, .001));
  });

  test(
    'short recovery windows and faster devices lower the measured reserve',
    () {
      final budget = SpeechPlaybackBudget()..record(16, 24);
      for (var i = 0; i < 3; i++) {
        budget.record(16, 4);
      }
      expect(budget.minimumSeconds(16, cold: false), 8);
      budget.record(double.nan, 100);
      budget.record(0, 100);
      expect(budget.minimumSeconds(8, cold: false), 8);
    },
  );
}
