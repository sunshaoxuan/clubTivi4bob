import 'package:clubtivi/features/player/playback_status_labels.dart';
import 'package:clubtivi/features/player/subtitle_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('subtitle label stays left of route label at narrow widths', (
    tester,
  ) async {
    final status = ValueNotifier(SubtitlePhase.englishFallback);
    addTearDown(status.dispose);
    final subtitle = find.byKey(const ValueKey('player-subtitle-status-label'));
    final route = find.byKey(const ValueKey('player-route-status-label'));

    for (final width in [560.0, 160.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              width: width,
              child: Align(
                alignment: Alignment.topRight,
                child: PlaybackStatusLabels(
                  routeLabel: '候选 1 路',
                  routeBusy: false,
                  subtitleStatus: status,
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getRect(subtitle).right,
        lessThan(tester.getRect(route).left),
      );
      expect(tester.getCenter(subtitle).dy, tester.getCenter(route).dy);
      expect(tester.getRect(subtitle).width, greaterThan(0));
      expect(tester.takeException(), isNull);
    }

    final rightEdge = tester.getRect(route).right;
    status.value = SubtitlePhase.synchronizing;
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.getRect(route).right, rightEdge);
    status.value = SubtitlePhase.ready;
    await tester.pump();
    expect(subtitle, findsNothing);
    expect(tester.getRect(route).right, rightEdge);
  });
}
