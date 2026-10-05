import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/features/player/fullscreen_programme_overlay.dart';

void main() {
  final now = DateTime(2026, 10, 6, 12, 30);
  db.EpgProgramme programme(int id, DateTime start, String title) =>
      db.EpgProgramme(
        id: id,
        sourceId: 'test',
        epgChannelId: 'CCTV6',
        title: title,
        start: start,
        stop: start.add(const Duration(hours: 1)),
      );
  Future<void> pump(
    WidgetTester tester, {
    List<db.EpgProgramme>? rows,
    int shift = 0,
    double width = 752,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(
            fontFamily: 'BobTVFullscreenPreview',
          ),
        ),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: RepaintBoundary(
                  key: const ValueKey('fullscreen-epg-preview'),
                  child: FullscreenProgrammeOverlay(
                    channelName: 'CCTV-6 电影',
                    now: now,
                    timeshiftHours: shift,
                    programmes:
                        rows ??
                        [
                          programme(
                            1,
                            now.subtract(const Duration(minutes: 30)),
                            '当前电影',
                          ),
                          programme(
                            2,
                            now.add(const Duration(minutes: 30)),
                            '下一部电影',
                          ),
                          programme(
                            3,
                            now.add(const Duration(minutes: 90)),
                            '第三部电影',
                          ),
                        ],
                    onReturn: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('Fullscreen shows current, next and third in the same timeline', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('CCTV-6 电影'), findsOneWidget);
    for (final title in ['当前电影', '下一部电影', '第三部电影', '正在播出', '接下来', '随后']) {
      expect(find.text(title), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'Missing EPG keeps channel and return controls without fake programmes',
    (tester) async {
      await pump(tester, rows: []);
      expect(find.text('CCTV-6 电影'), findsOneWidget);
      expect(find.text('返回频道'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('channel-programme-strip')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'Timeshift and large fonts keep current labels and usable layout',
    (tester) async {
      await pump(
        tester,
        shift: 2,
        scale: 1.5,
        rows: [
          programme(1, now.subtract(const Duration(minutes: 150)), '时差后的当前节目'),
          programme(2, now.subtract(const Duration(minutes: 90)), '下一节目'),
          programme(3, now.subtract(const Duration(minutes: 30)), '第三节目'),
        ],
      );
      expect(find.text('正在播出'), findsOneWidget);
      expect(find.text('时差后的当前节目'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'renders fullscreen programme visual preview',
    (tester) async {
      await tester.runAsync(() async {
        final loader = FontLoader('BobTVFullscreenPreview');
        loader.addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '/System/Library/Fonts/STHeiti Light.ttc',
              ).readAsBytes(),
            ),
          ),
        );
        await loader.load();
        final icons = FontLoader('MaterialIcons');
        icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });
      await pump(tester);
      await expectLater(
        find.byKey(const ValueKey('fullscreen-epg-preview')),
        matchesGoldenFile('/tmp/bobtv-fullscreen-epg-preview.png'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: Platform.environment['BOBTV_FULLSCREEN_EPG_VISUAL'] != '1',
  );
}
