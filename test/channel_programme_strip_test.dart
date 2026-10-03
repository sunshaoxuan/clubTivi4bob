import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/features/channels/channel_programme_strip.dart';
import 'package:clubtivi/features/channels/inline_expanded_channel_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 10, 3, 8, 30);

db.EpgProgramme _programme(int id, int hour, {String? title, int day = 3}) =>
    db.EpgProgramme(
      id: id,
      epgChannelId: 'cctv6',
      sourceId: 'test',
      title: title ?? '电影节目 $id',
      start: DateTime(2026, 10, day, hour),
      stop: DateTime(2026, 10, day, hour + 1),
    );

Future<void> _pumpStrip(
  WidgetTester tester, {
  required List<db.EpgProgramme> programmes,
  double width = 750,
  double scale = 1,
  int timeshiftHours = 0,
  DateTime? now,
  bool previewFont = false,
  bool combined = false,
  List<String> previewChannelIds = const ['CCTV1', 'CCTV6', 'CCTV9'],
}) async {
  final strip = ChannelProgrammeStrip(
    channelName: 'CCTV-6 电影',
    programmes: programmes,
    timeshiftHours: timeshiftHours,
    now: now ?? _now,
    embedded: combined,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        textTheme: ThemeData.dark(useMaterial3: true).textTheme.apply(
          fontFamily: previewFont ? 'BobTVProgrammePreview' : null,
        ),
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: SizedBox(
              width: width,
              child: RepaintBoundary(
                key: const ValueKey('programme-strip-preview'),
                child: combined
                    ? SizedBox(
                        height: 490,
                        child: InlineExpandedChannelGrid(
                          channelIds: previewChannelIds,
                          columns: previewChannelIds.length,
                          expandedChannelId: 'CCTV6',
                          expandedContent: strip,
                          cardBuilder: (_, index) => Container(
                            padding: const EdgeInsets.all(18),
                            alignment: Alignment.bottomLeft,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              gradient: const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xFF334A63), Color(0xFF101C2C)],
                              ),
                            ),
                            child: Text(
                              const {
                                'CCTV1': 'CCTV-1 综合',
                                'CCTV6': 'CCTV-6 电影',
                                'CCTV9': 'CCTV-9 纪录',
                                'CCTV2': 'CCTV-2 财经',
                                'CCTV3': 'CCTV-3 综艺',
                              }[previewChannelIds[index]]!,
                              style: const TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      )
                    : strip,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows current and two next programmes in schedule order', (
    tester,
  ) async {
    await _pumpStrip(
      tester,
      programmes: [
        _programme(4, 11),
        _programme(3, 10),
        _programme(1, 8),
        _programme(2, 9),
        _programme(0, 7),
      ],
    );
    expect(find.byKey(const ValueKey('programme-0')), findsNothing);
    expect(find.byKey(const ValueKey('programme-4')), findsNothing);
    expect(find.byKey(const ValueKey('programme-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('programme-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('programme-3')), findsOneWidget);
    expect(find.text('正在播出'), findsOneWidget);
    expect(find.text('接下来'), findsOneWidget);
    expect(find.text('随后'), findsOneWidget);
    expect(find.text('08:00 ~ 09:00'), findsOneWidget);
    expect(find.text('08:00'), findsOneWidget);
    expect(find.text('09:00'), findsOneWidget);
    expect(find.text('10:00'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('programme-timeline-node-1')),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.text('08:00')).dx,
      lessThan(tester.getTopLeft(find.text('09:00')).dx),
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .5,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty and expired schedules do not reserve space', (
    tester,
  ) async {
    await _pumpStrip(tester, programmes: []);
    expect(find.byKey(const ValueKey('channel-programme-strip')), findsNothing);
    await _pumpStrip(tester, programmes: [_programme(1, 7)]);
    expect(find.byKey(const ValueKey('channel-programme-strip')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('applies time shift to both selection and displayed schedule', (
    tester,
  ) async {
    await _pumpStrip(
      tester,
      programmes: [_programme(1, 7), _programme(2, 8)],
      timeshiftHours: 1,
    );
    expect(find.text('正在播出'), findsOneWidget);
    expect(find.text('08:00 ~ 09:00'), findsOneWidget);
    expect(find.byKey(const ValueKey('programme-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('end is exclusive and start is inclusive at the time boundary', (
    tester,
  ) async {
    await _pumpStrip(
      tester,
      programmes: [_programme(1, 8), _programme(2, 9)],
      now: DateTime(2026, 10, 3, 9),
    );
    expect(find.byKey(const ValueKey('programme-1')), findsNothing);
    expect(find.byKey(const ValueKey('programme-2')), findsOneWidget);
    expect(find.text('正在播出'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0,
    );
  });

  testWidgets('tomorrow label distinguishes a schedule across midnight', (
    tester,
  ) async {
    await _pumpStrip(
      tester,
      programmes: [_programme(1, 23), _programme(2, 0, day: 4)],
      now: DateTime(2026, 10, 3, 23, 30),
    );
    expect(find.text('明天'), findsOneWidget);
    expect(find.text('00:00 ~ 01:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('260 px layout stays usable with text scale $scale', (
      tester,
    ) async {
      await _pumpStrip(
        tester,
        width: 260,
        scale: scale,
        programmes: [
          _programme(1, 8, title: '特别长的节目名称和电影介绍也应当保持两行的整齐排版'),
          _programme(2, 9),
          _programme(3, 10),
        ],
      );
      expect(tester.takeException(), isNull);
      final scrollbar = tester.widget<Scrollbar>(
        find.byKey(const ValueKey('programme-scrollbar')),
      );
      expect(scrollbar.thumbVisibility, isTrue);
      expect(scrollbar.interactive, isTrue);
      expect(
        find.byKey(const ValueKey('programme-scroll-next')),
        findsOneWidget,
      );
      final before = scrollbar.controller!.offset;
      await tester.tap(find.byKey(const ValueKey('programme-scroll-next')));
      await tester.pumpAndSettle();
      expect(scrollbar.controller!.offset, greaterThan(before));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('programme-scroll-previous')));
      await tester.pumpAndSettle();
      expect(scrollbar.controller!.offset, closeTo(0, 1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('wide layout shows three cards without scroll controls', (
    tester,
  ) async {
    await _pumpStrip(
      tester,
      programmes: [_programme(1, 8), _programme(2, 9), _programme(3, 10)],
    );
    expect(find.byKey(const ValueKey('programme-scroll-next')), findsNothing);
    final scrollbar = tester.widget<Scrollbar>(
      find.byKey(const ValueKey('programme-scrollbar')),
    );
    expect(scrollbar.thumbVisibility, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a future-only schedule identifies just the first programme as next',
    (tester) async {
      await _pumpStrip(
        tester,
        programmes: [_programme(1, 9), _programme(2, 10), _programme(3, 11)],
      );
      expect(find.text('正在播出'), findsNothing);
      expect(find.text('接下来'), findsOneWidget);
      expect(find.text('随后'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('overlapping entries use the latest current programme', (
    tester,
  ) async {
    final old = db.EpgProgramme(
      id: 0,
      epgChannelId: 'cctv6',
      sourceId: 'test',
      title: '旧节目',
      start: DateTime(2026, 10, 3, 7),
      stop: DateTime(2026, 10, 3, 9),
    );
    await _pumpStrip(
      tester,
      programmes: [old, _programme(1, 8), _programme(2, 9), _programme(3, 10)],
    );
    expect(find.text('旧节目'), findsNothing);
    expect(find.text('正在播出'), findsOneWidget);
    expect(find.byKey(const ValueKey('programme-1')), findsOneWidget);
  });

  // Optional, local visual QA. No image or platform font is required in CI.
  testWidgets(
    'renders programme strip visual previews',
    (tester) async {
      await tester.runAsync(() async {
        final font = File('/System/Library/Fonts/STHeiti Light.ttc');
        final loader = FontLoader('BobTVProgrammePreview');
        loader.addFont(
          Future.value(ByteData.sublistView(await font.readAsBytes())),
        );
        await loader.load();
        final iconLoader = FontLoader('MaterialIcons');
        iconLoader.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await iconLoader.load();
      });
      final programmes = [
        _programme(1, 8, title: '光影星播客 · 今日电影'),
        _programme(2, 9, title: '故事片：海边的日子'),
        _programme(3, 10, title: '中国电影报道'),
      ];
      await _pumpStrip(
        tester,
        programmes: programmes,
        width: 736,
        previewFont: true,
      );
      await expectLater(
        find.byKey(const ValueKey('programme-strip-preview')),
        matchesGoldenFile('/tmp/bobtv-channel-programme-strip-wide.png'),
      );
      await _pumpStrip(
        tester,
        programmes: programmes,
        width: 320,
        previewFont: true,
      );
      await expectLater(
        find.byKey(const ValueKey('programme-strip-preview')),
        matchesGoldenFile('/tmp/bobtv-channel-programme-strip-narrow.png'),
      );
      await _pumpStrip(
        tester,
        programmes: programmes,
        width: 790,
        previewFont: true,
        combined: true,
      );
      await expectLater(
        find.byKey(const ValueKey('programme-strip-preview')),
        matchesGoldenFile('/tmp/bobtv-channel-programme-timeline-framed.png'),
      );
      await _pumpStrip(
        tester,
        programmes: programmes,
        width: 790,
        previewFont: true,
        combined: true,
        previewChannelIds: const ['CCTV6', 'CCTV1', 'CCTV9'],
      );
      await expectLater(
        find.byKey(const ValueKey('programme-strip-preview')),
        matchesGoldenFile('/tmp/bobtv-channel-programme-timeline-left.png'),
      );
      for (var columns = 1; columns <= 5; columns++) {
        for (var selected = 0; selected < columns; selected++) {
          final ids = [
            'CCTV6',
            'CCTV1',
            'CCTV9',
            'CCTV2',
            'CCTV3',
          ].take(columns).toList()..remove('CCTV6');
          ids.insert(selected, 'CCTV6');
          await _pumpStrip(
            tester,
            programmes: programmes,
            width: 790,
            previewFont: true,
            combined: true,
            previewChannelIds: ids,
          );
          await expectLater(
            find.byKey(const ValueKey('programme-strip-preview')),
            matchesGoldenFile(
              '/tmp/bobtv-programme-$columns-columns-position-$selected.png',
            ),
          );
          expect(tester.takeException(), isNull);
        }
      }
    },
    skip: !const bool.fromEnvironment('BOBTV_PROGRAMME_STRIP_PREVIEW'),
  );
}
