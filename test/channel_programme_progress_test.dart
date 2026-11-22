import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/features/channels/channel_programme_preview.dart';
import 'package:clubtivi/features/channels/channel_programme_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<db.EpgProgramme> _schedule() => [
  for (var hour = 8; hour < 15; hour++)
    db.EpgProgramme(
      id: hour,
      epgChannelId: 'test',
      sourceId: 'fixture',
      title: 'Programme $hour',
      start: DateTime(2026, 11, 22, hour),
      stop: DateTime(2026, 11, 22, hour + 1),
    ),
];

Finder _paint(int id) => find.descendant(
  of: find.byKey(ValueKey('programme-timeline-node-$id')),
  matching: find.byType(CustomPaint),
);

void main() {
  testWidgets('only current rail has a moving dot and elapsed green segment', (
    tester,
  ) async {
    var now = DateTime(2026, 11, 22, 8, 30);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(),
          child: Scaffold(
            body: SizedBox(
              width: 600,
              child: ChannelProgrammeStrip(
                channelName: 'Test',
                programmes: _schedule(),
                compact: true,
                clock: () => now,
              ),
            ),
          ),
        ),
      ),
    );
    void expectPosition(double fraction) {
      final size = tester.getSize(_paint(8));
      expect(
        _paint(8),
        paints
          ..line(color: const Color(0xFF43D48C))
          ..line(color: const Color(0xFF1F754B))
          ..circle(hasMaskFilter: true)
          ..circle(
            x: 4 + (size.width - 8) * fraction,
            y: size.height / 2,
            radius: 3,
          ),
      );
    }

    expectPosition(.5);
    await tester.pump(const Duration(milliseconds: 700));
    expect(
      _paint(8),
      paints
        ..circle(radius: 5.75, hasMaskFilter: true)
        ..circle(radius: 3),
    );
    expect(_paint(9), paintsExactlyCountTimes(#drawCircle, 0));
    expect(_paint(10), paintsExactlyCountTimes(#drawCircle, 0));
    expect(
      _paint(9),
      paints..line(color: const Color(0xFF8FCBA8).withValues(alpha: .65)),
    );
    expect(
      _paint(10),
      paints..line(color: const Color(0xFFBCE2CD).withValues(alpha: .38)),
    );
    now = DateTime(2026, 11, 22, 8, 45);
    await tester.pump(const Duration(seconds: 1));
    expectPosition(.75);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final timeshift in [0, 1]) {
    testWidgets(
      'rollover advances and refills all three slots, shift $timeshift',
      (tester) async {
        var now = DateTime(2026, 11, 22, 8 + timeshift, 59, 59);
        final calls = <DateTime>[];
        final preview = ChannelProgrammePreview(
          clock: () => now,
          load: (_, at, limit) async {
            calls.add(at);
            return _schedule()
                .where((p) => p.stop.isAfter(at))
                .take(limit)
                .toList();
          },
        );
        addTearDown(preview.dispose);
        Future<void> refresh() => preview.select(
          channelId: 'selected',
          epgChannelId: 'test',
          timeshiftHours: timeshift,
          forceRefresh: true,
        );
        await refresh();
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: Scaffold(
                body: SizedBox(
                  width: 600,
                  child: AnimatedBuilder(
                    animation: preview,
                    builder: (_, _) => ChannelProgrammeStrip(
                      channelName: 'Test',
                      programmes: preview.programmes,
                      timeshiftHours: preview.timeshiftHours,
                      clock: () => now,
                      compact: true,
                      onProgrammeBoundary: refresh,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        for (var current = 9; current <= 11; current++) {
          now = DateTime(2026, 11, 22, current + timeshift);
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
          await tester.pump();
          expect(preview.selectedChannelId, 'selected');
          expect(find.text('Programme ${current - 1}'), findsNothing);
          for (var id = current; id < current + 3; id++) {
            expect(find.text('Programme $id'), findsOneWidget);
          }
          expect(_paint(current), paintsExactlyCountTimes(#drawCircle, 2));
          expect(_paint(current + 1), paintsExactlyCountTimes(#drawCircle, 0));
          expect(_paint(current + 2), paintsExactlyCountTimes(#drawCircle, 0));
          expect(calls.last, DateTime(2026, 11, 22, current));
        }
        expect(calls.length, 4);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
