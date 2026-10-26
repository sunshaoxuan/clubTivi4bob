import 'dart:async';

import 'package:clubtivi/features/channels/radio_card_spectrum.dart';
import 'package:clubtivi/features/player/radio_audio_spectrum.dart';
import 'package:clubtivi/features/player/radio_playback_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class SignalReader implements RadioSpectrumReader {
  int attachments = 0;
  int detachments = 0;
  int reads = 0;
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
    return RadioSpectrumMeasurement(
      signalLevels: List.filled(RadioSpectrumAnalysis.bandCount, .7),
      volume: 0,
      muted: true,
    );
  }
}

void main() {
  testWidgets('muted card shows real input levels and keeps taps available', (
    tester,
  ) async {
    final reader = SignalReader();
    final spectrum = RadioAudioSpectrum(reader);
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: SizedBox(
              width: 200,
              height: 50,
              child: RadioCardSpectrum(
                spectrum: spectrum,
                initialPlaying: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(spectrum.signalLevels, everyElement(.7));
    expect(spectrum.levels, everyElement(0));
    final waveform = tester.widget<RadioWaveform>(find.byType(RadioWaveform));
    expect(waveform.signalOnly, isTrue);
    expect(
      tester.getSize(find.byType(RadioWaveform)).width,
      lessThanOrEqualTo(120),
    );
    expect(
      tester.getSize(find.byType(RadioWaveform)).height,
      lessThanOrEqualTo(28),
    );
    await tester.tapAt(tester.getCenter(find.byType(RadioCardSpectrum)));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(reader.detachments, 1);
  });

  testWidgets(
    'preview to main handoff shares analysis and stops while buffering',
    (tester) async {
      final reader = SignalReader();
      final spectrum = RadioAudioSpectrum(reader);
      final buffering = StreamController<bool>.broadcast(sync: true);
      Widget view({bool main = false}) => MaterialApp(
        home: SizedBox(
          width: 200,
          height: 100,
          child: main
              ? RadioWaveform(playing: true, spectrum: spectrum)
              : RadioCardSpectrum(
                  spectrum: spectrum,
                  initialPlaying: true,
                  buffering: buffering.stream,
                ),
        ),
      );
      await tester.pumpWidget(view());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      buffering.add(true);
      await tester.pump();
      expect(
        tester.widget<RadioWaveform>(find.byType(RadioWaveform)).playing,
        isFalse,
      );
      final reads = reader.reads;
      await tester.pump(const Duration(seconds: 1));
      expect(reader.reads, reads);
      expect(spectrum.signalLevels, everyElement(0));
      buffering.add(false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(spectrum.signalLevels, everyElement(.7));
      final before = reader.attachments;
      await tester.pumpWidget(view(main: true));
      await tester.pump();
      expect(reader.attachments, before);
      expect(
        tester.widget<RadioWaveform>(find.byType(RadioWaveform)).signalOnly,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await buffering.close();
    },
  );
}
