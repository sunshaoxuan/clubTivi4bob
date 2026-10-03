import 'package:clubtivi/features/channels/channel_card_playback_binding.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

class _PaintCounter extends CustomPainter {
  _PaintCounter(this.onPaint, {Listenable? tick}) : super(repaint: tick);
  final VoidCallback onPaint;
  @override
  void paint(Canvas canvas, Size size) {
    onPaint();
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.blue);
  }

  @override
  bool shouldRepaint(_PaintCounter oldDelegate) => false;
}

void main() {
  testWidgets('100 route updates do not rebuild unrelated visible cards', (
    tester,
  ) async {
    final preview = ValueNotifier<VideoController?>(null);
    final main = ValueNotifier<RouteSearchProgress?>(null);
    final progress = ValueNotifier<RouteSearchProgress?>(null);
    final builds = <String, int>{};
    Widget card(String id, {bool pending = false, bool selected = false}) =>
        ChannelCardPlaybackBinding(
          channelId: id,
          selected: selected,
          pending: pending,
          preparedChannelId: () => 'pending',
          previewController: preview,
          mainProgress: main,
          previewProgress: progress,
          builder: (_, route, busy) {
            builds[id] = (builds[id] ?? 0) + 1;
            return Text('$id ${route?.index ?? 0} $busy');
          },
        );
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            card('pending', pending: true),
            card('playing', selected: true),
            for (var index = 0; index < 10; index++) card('idle-$index'),
          ],
        ),
      ),
    );
    for (var index = 1; index <= 100; index++) {
      progress.value = RouteSearchProgress(
        stage: '正在尝试线路',
        index: index,
        total: 100,
        active: true,
      );
      await tester.pump();
    }
    expect(builds['pending'], 101);
    expect(builds['playing'], 1);
    for (var index = 0; index < 10; index++) {
      expect(builds['idle-$index'], 1);
    }
    main.value = const RouteSearchProgress(
      stage: '正在切换',
      index: 1,
      total: 3,
      active: true,
    );
    await tester.pump();
    expect(builds['playing'], 2);
    expect(builds['pending'], 101);
    await tester.pumpWidget(const SizedBox.shrink());
    progress.value = null; // Disposed cards must no longer receive updates.
    preview.dispose();
    main.dispose();
    progress.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('animated preview does not repaint adjacent static cards', (
    tester,
  ) async {
    final tick = ValueNotifier<int>(0);
    final preview = ValueNotifier<VideoController?>(null);
    final progress = ValueNotifier<RouteSearchProgress?>(null);
    var staticPaints = 0;
    var videoPaints = 0;
    Widget card(bool video) => SizedBox(
      width: 240,
      height: 172,
      child: ChannelCardPlaybackBinding(
        channelId: video ? 'video' : 'static',
        selected: false,
        pending: false,
        preparedChannelId: () => null,
        previewController: preview,
        mainProgress: progress,
        previewProgress: progress,
        builder: (_, __, ___) => CustomPaint(
          painter: _PaintCounter(() {
            if (video) {
              videoPaints++;
            } else {
              staticPaints++;
            }
          }, tick: video ? tick : null),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [card(true), card(false)],
          ),
        ),
      ),
    );
    final initialStaticPaints = staticPaints;
    for (var frame = 1; frame <= 60; frame++) {
      tick.value = frame;
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(videoPaints, greaterThanOrEqualTo(60));
    expect(staticPaints, initialStaticPaints);
    await tester.pumpWidget(const SizedBox.shrink());
    tick.dispose();
    preview.dispose();
    progress.dispose();
  });
}
