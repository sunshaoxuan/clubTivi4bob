import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:clubtivi/core/i18n/app_language.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/features/player/fullscreen_programme_overlay.dart';

class _FileMessagesDelegate extends LocalizationsDelegate<AppMessages> {
  const _FileMessagesDelegate(this.language);
  final AppLanguage language;
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<AppMessages> load(Locale locale) => SynchronousFuture(
    AppMessages(
      (jsonDecode(File(language.bundlePath).readAsStringSync()) as Map)
          .cast<String, String>(),
      (jsonDecode(File(AppLanguage.english.bundlePath).readAsStringSync())
              as Map)
          .cast<String, String>(),
    ),
  );
  @override
  bool shouldReload(_FileMessagesDelegate old) => language != old.language;
}

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
    AppLanguage? language,
  }) async {
    tester.view.physicalSize = Size(width, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: language?.locale,
        supportedLocales: AppLanguage.values.map((l) => l.locale),
        localizationsDelegates: language == null
            ? null
            : [
                _FileMessagesDelegate(language),
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
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
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  for (final language in AppLanguage.values) {
    testWidgets(
      '${language.tag} localizes next/later hints including empty slots',
      (tester) async {
        final messages =
            (jsonDecode(File(language.bundlePath).readAsStringSync()) as Map)
                .cast<String, String>();
        await pump(
          tester,
          language: language,
          rows: [
            programme(1, now.subtract(const Duration(minutes: 30)), 'Film one'),
            programme(2, now.add(const Duration(minutes: 30)), 'Film two'),
          ],
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('${messages['接下来']}：Film two'),
          findsOneWidget,
        );
        expect(find.textContaining(messages['随后']!), findsOneWidget);
        if (language != AppLanguage.simplifiedChinese &&
            language != AppLanguage.traditionalChinese) {
          expect(find.textContaining('接下来'), findsNothing);
          expect(find.textContaining('随后'), findsNothing);
        }
      },
    );
  }

  testWidgets('Fullscreen shows current, next and third as lightweight text', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('CCTV-6 电影'), findsOneWidget);
    expect(find.text('当前电影'), findsOneWidget);
    expect(find.textContaining('接下来：下一部电影'), findsOneWidget);
    expect(find.textContaining('随后：第三部电影'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
    expect(find.byKey(const ValueKey('channel-programme-strip')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'Missing EPG keeps the channel without adding navigation or programmes',
    (tester) async {
      await pump(tester, rows: []);
      expect(find.text('CCTV-6 电影'), findsOneWidget);
      expect(find.text('返回频道'), findsNothing);
      expect(find.byIcon(Icons.power_settings_new_rounded), findsNothing);
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
      expect(find.text('时差后的当前节目'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('Narrow window and long titles remain usable', (tester) async {
    await pump(
      tester,
      width: 360,
      scale: 1.5,
      rows: [
        programme(
          1,
          now.subtract(const Duration(minutes: 30)),
          '当前节目标题较长，用于验证窄窗口中的文字换行与布局',
        ),
        programme(
          2,
          now.add(const Duration(minutes: 30)),
          '下一个节目标题较长，用于验证时间与文字的显示',
        ),
      ],
    );
    expect(find.text('返回频道'), findsNothing);
    expect(find.textContaining('接下来：'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'Channel and guide keep their alignment without header navigation',
    (tester) async {
      for (final width in [752.0, 1440.0, 3840.0]) {
        await pump(tester, width: width);
        final name = tester.getRect(find.text('CCTV-6 电影'));
        final guide = tester.getRect(
          find.byKey(const ValueKey('fullscreen-programme-region')),
        );
        expect(name.left, closeTo(12, 1));
        expect(guide.center.dx, closeTo(width / 2, 1));
        expect(find.text('返回频道'), findsNothing);
        expect(guide.height, lessThan(150));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('Missing third entry is explicit without inventing a programme', (
    tester,
  ) async {
    await pump(
      tester,
      rows: [
        programme(1, now.subtract(const Duration(minutes: 30)), '当前电影'),
        programme(2, now.add(const Duration(minutes: 30)), '下一部电影'),
      ],
    );
    expect(find.text('当前电影'), findsOneWidget);
    expect(find.textContaining('接下来：下一部电影'), findsOneWidget);
    expect(find.text('随后：暂无节目单'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
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
