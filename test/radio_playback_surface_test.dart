import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:clubtivi/features/player/radio_playback_surface.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'paint clock is bounded to 20 Hz and stops without accumulating work',
    () {
      fakeAsync((time) {
        final clock = RadioWaveClock();
        var changes = 0;
        clock.addListener(() => changes++);
        clock.setRunning(true);
        expect(changes, 1);
        time.elapse(const Duration(seconds: 1));
        expect(changes, 21);
        clock.setRunning(true);
        expect(changes, 21);
        clock.setRunning(false);
        final phase = clock.phase;
        time.elapse(const Duration(seconds: 5));
        expect(clock.phase, phase);
        expect(changes, 22);
        clock.setRunning(true);
        clock.dispose();
        time.elapse(const Duration(seconds: 5));
        expect(time.periodicTimerCount, 0);
      });
    },
  );

  Future<void> pumpSurface(
    WidgetTester tester, {
    Size size = const Size(800, 450),
    bool playing = true,
    Stream<bool> playback = const Stream<bool>.empty(),
    Stream<bool> buffering = const Stream<bool>.empty(),
    bool initialBuffering = false,
    bool tickerEnabled = true,
    bool reduceMotion = false,
    double textScale = 1,
    String? logoUrl,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(
            fontFamily: 'BobTVRadioPreview',
          ),
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox.fromSize(
              size: size,
              child: MediaQuery(
                data: MediaQueryData(
                  disableAnimations: reduceMotion,
                  textScaler: TextScaler.linear(textScale),
                ),
                child: TickerMode(
                  enabled: tickerEnabled,
                  child: RepaintBoundary(
                    key: const ValueKey('radio-preview-capture'),
                    child: RadioPlaybackSurface(
                      channelName: 'FM 93.1',
                      logoUrl: logoUrl,
                      playing: playback,
                      buffering: buffering,
                      initialPlaying: playing,
                      initialBuffering: initialBuffering,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('station artwork is above waveform and keeps the exact name', (
    tester,
  ) async {
    await pumpSurface(tester, logoUrl: '  ');
    final artwork = tester.getRect(
      find.byKey(const ValueKey('radio-station-artwork')),
    );
    final waveform = tester.getRect(
      find.byKey(const ValueKey('radio-waveform')),
    );
    expect(artwork.bottom, lessThan(waveform.top));
    expect(find.text('FM 93.1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('radio-artwork-fallback')),
      findsOneWidget,
    );
    expect(find.byType(Image), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('small windows and large text do not overflow', (tester) async {
    for (final size in [
      const Size(356, 200),
      const Size(320, 100),
      const Size(64, 40),
      const Size(640, 360),
    ]) {
      await pumpSurface(tester, size: size, textScale: 2);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pause and buffering update only the waveform state', (
    tester,
  ) async {
    final playing = StreamController<bool>.broadcast(sync: true);
    final buffering = StreamController<bool>.broadcast(sync: true);
    await pumpSurface(
      tester,
      playback: playing.stream,
      buffering: buffering.stream,
    );
    RadioWaveform waveform() =>
        tester.widget<RadioWaveform>(find.byType(RadioWaveform));
    expect(waveform().playing, isTrue);
    buffering.add(true);
    await tester.pump();
    expect(waveform().playing, isFalse);
    buffering.add(false);
    await tester.pump();
    expect(waveform().playing, isTrue);
    playing.add(false);
    await tester.pump();
    expect(waveform().playing, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(playing.hasListener, isFalse);
    expect(buffering.hasListener, isFalse);
    await playing.close();
    await buffering.close();
  });

  testWidgets('animation does not rebuild the surrounding page', (
    tester,
  ) async {
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (_) {
            builds++;
            return const SizedBox(
              width: 800,
              height: 450,
              child: RadioPlaybackSurface(
                channelName: 'FM 93.1',
                initialPlaying: true,
              ),
            );
          },
        ),
      ),
    );
    final before = builds;
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(builds, before);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'hidden, background and reduced-motion views stop scheduling paints',
    (tester) async {
      await pumpSurface(tester, tickerEnabled: false);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
      await pumpSurface(tester, reduceMotion: true);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
      await pumpSurface(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets('radio surface keeps parent tap controls usable', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: GestureDetector(
          onTap: () => taps++,
          child: const RadioPlaybackSurface(channelName: 'FM 93.1'),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('radio-station-artwork')));
    expect(taps, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'optional local visual preview',
    (tester) async {
      final path = Platform.environment['BOBTV_RADIO_PREVIEW_PATH']!;
      final fontPath = Platform.environment['BOBTV_RADIO_PREVIEW_FONT_PATH'];
      if (fontPath != null) {
        await tester.runAsync(() async {
          final font = FontLoader('BobTVRadioPreview')
            ..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
          await font.load();
          final icons = FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
          await icons.load();
        });
      }
      await pumpSurface(tester);
      await tester.pump(const Duration(milliseconds: 350));
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('radio-preview-capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(path).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: Platform.environment['BOBTV_RADIO_PREVIEW_PATH'] == null,
  );
}
