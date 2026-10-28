import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/features/player/radio_audio_spectrum.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

String metadata(double left, double right) => jsonEncode({
  'lavfi.bobtv_spectrum.ready': '1',
  for (var i = 0; i < RadioSpectrumAnalysis.bandCount; i++)
    'lavfi.bobtv_spectrum.$i': '${left > right ? left : right}',
});

class TestReader implements RadioSpectrumReader {
  int attachments = 0;
  int detachments = 0;
  int reads = 0;
  List<double>? frame;
  Completer<List<double>?>? delayed;
  @override
  Future<bool> attach() async {
    attachments++;
    return true;
  }

  @override
  Future<void> detach() async {
    detachments++;
  }

  @override
  Future<RadioSpectrumMeasurement?> read() async {
    reads++;
    final signal = delayed != null ? await delayed!.future : frame;
    return signal == null
        ? null
        : RadioSpectrumMeasurement(signalLevels: signal);
  }
}

void main() {
  test(
    '128 measured bands are partitioned into safe native channel layouts',
    () {
      expect(RadioSpectrumAnalysis.frequencies.length, 128);
      expect(RadioSpectrumAnalysis.frequencies.first, 40);
      expect(RadioSpectrumAnalysis.frequencies.last, closeTo(16000, .01));
      expect(RadioSpectrumAnalysis.filter, contains('bobtv_spectrum'));
    },
  );
  test('band values come from PCM metadata with an absolute dBFS scale', () {
    expect(RadioSpectrumAnalysis.parse(metadata(-36, -72)), everyElement(.5));
    expect(RadioSpectrumAnalysis.parse(metadata(-72, -18)), everyElement(.75));
    expect(RadioSpectrumAnalysis.parse(metadata(-90, -90)), everyElement(0));
    expect(RadioSpectrumAnalysis.parse(metadata(3, 3)), everyElement(1));
    expect(
      RadioSpectrumAnalysis.parse(
        metadata(double.negativeInfinity, double.negativeInfinity),
      ),
      everyElement(0),
    );
    expect(
      RadioSpectrumAnalysis.parse(metadata(-18, -18), volume: 0),
      everyElement(0),
    );
    expect(RadioSpectrumAnalysis.parse('{}'), isNull);
    expect(RadioSpectrumAnalysis.parse('unavailable'), isNull);
    expect(
      RadioSpectrumAnalysis.parse(metadata(double.nan, double.nan)),
      isNull,
    );
  });

  test('one bounded sampler is shared and waits for each native read', () {
    fakeAsync((time) {
      final reader = TestReader()
        ..frame = List.filled(RadioSpectrumAnalysis.bandCount, .5);
      final spectrum = RadioAudioSpectrum(reader);
      spectrum.acquire();
      spectrum.acquire();
      time.flushMicrotasks();
      expect(reader.attachments, 1);
      time.elapse(const Duration(seconds: 1));
      expect(reader.reads, 20);
      expect(spectrum.levels, everyElement(.5));
      reader.delayed = Completer<List<double>?>();
      time.elapse(const Duration(seconds: 1));
      expect(reader.reads, 21);
      spectrum.release();
      spectrum.release();
      reader.delayed!.complete(null);
      time.flushMicrotasks();
      expect(reader.detachments, 1);
      expect(spectrum.available, isFalse);
      expect(spectrum.levels, everyElement(0));
      time.elapse(const Duration(seconds: 2));
      expect(reader.reads, 21);
      expect(time.nonPeriodicTimerCount, 0);
    });
  });

  test('handoff and missing data never replay previous audio levels', () {
    fakeAsync((time) {
      final reader = TestReader()
        ..frame = List.filled(RadioSpectrumAnalysis.bandCount, .8);
      final spectrum = RadioAudioSpectrum(reader);
      spectrum.acquire();
      time.flushMicrotasks();
      time.elapse(const Duration(milliseconds: 50));
      spectrum.release();
      spectrum.acquire();
      time.flushMicrotasks();
      expect(reader.attachments, 1);
      reader.frame = null;
      time.elapse(const Duration(milliseconds: 50));
      expect(spectrum.available, isFalse);
      expect(spectrum.levels, everyElement(0));
      spectrum.release();
      time.flushMicrotasks();
      expect(reader.detachments, 1);
      expect(time.nonPeriodicTimerCount, 0);
    });
  });

  test('export the exact production filter for the native signal probe', () {
    final path = Platform.environment['BOBTV_RADIO_NATIVE_FILTER_PATH'];
    if (path != null) {
      File(path).writeAsStringSync(RadioSpectrumAnalysis.filter);
    }
    expect(RadioSpectrumAnalysis.filter, contains('lavfi=[bobtv_spectrum]'));
  });
}
