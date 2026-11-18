import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/features/player/client_audio_window.dart';

Uint8List samples(int count, int value) =>
    Int16List.fromList(List.filled(count, value)).buffer.asUint8List();

void main() {
  test(
    'recognition input safely amplifies quiet PCM without moving samples',
    () {
      final quiet = Uint8List(16);
      final data = ByteData.sublistView(quiet);
      data.setInt16(0, 200, Endian.little);
      data.setInt16(4, -200, Endian.little);
      final adjusted = prepareRecognitionPcm(quiet);
      expect(adjusted.gain, 3);
      expect(adjusted.bytes.length, quiet.length);
      expect(data.getInt16(0, Endian.little), 200);
      final result = ByteData.sublistView(adjusted.bytes);
      expect(result.getInt16(0, Endian.little), 600);
      expect(result.getInt16(2, Endian.little), 0);
      expect(result.getInt16(4, Endian.little), -600);
      expect(prepareRecognitionPcm(Uint8List(16)).gain, 1);
      data.setInt16(6, 25000, Endian.little);
      expect(prepareRecognitionPcm(quiet).gain, 1);
    },
  );

  test('early recovery attempts retain the first cue for a longer phrase', () {
    final chunks = <PcmChunk>[];
    for (var second = 0; second < 32; second++) {
      chunks.add((start: 100.0 + second, bytes: samples(16000, second + 1)));
      retainPcmContext(chunks, 101.0 + second, mobile: false);
      if (second == 5) {
        expect(buildPcmWindow(chunks)!.duration, 6);
      }
    }
    final window = buildPcmWindow(chunks)!;
    expect(window.start, 100);
    expect(window.end, 132);
    final pcm = window.bytes.buffer.asInt16List();
    expect(pcm.first, 1);
    expect(pcm[18 * 16000], 19);
    expect(pcm.last, 32);
  });

  test('mobile recovery retains a sentence with bounded PCM history', () {
    final chunks = <PcmChunk>[];
    for (var second = 0; second < 120; second++) {
      chunks.add((start: second.toDouble(), bytes: samples(16000, second)));
      retainPcmContext(chunks, second + 1.0, mobile: true);
    }
    final window = buildPcmWindow(chunks)!;
    expect(window.duration, lessThanOrEqualTo(17));
    expect(window.duration, greaterThanOrEqualTo(16));
    expect(window.end, 120);
    expect(window.bytes.buffer.asInt16List().last, 119);
  });

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

  test(
    'a music stall cannot monopolize a fast recovery worker for 40 seconds',
    () {
      final budget = SpeechPlaybackBudget()..record(32, 14);
      expect(budget.recoveryTimeoutSeconds(12), 15);
      budget.record(16, 24);
      expect(budget.recoveryTimeoutSeconds(8), 23);
      expect(budget.recoveryTimeoutSeconds(32), 40);
    },
  );
}
