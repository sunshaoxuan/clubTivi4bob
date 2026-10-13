import 'dart:io';

import 'package:clubtivi/core/tablet_presentation.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/features/channels/adaptive_home_toolbar.dart';
import 'package:clubtivi/features/channels/channel_programme_strip.dart';
import 'package:clubtivi/features/channels/compact_category_row.dart';
import 'package:clubtivi/features/channels/inline_expanded_channel_grid.dart';
import 'package:clubtivi/features/channels/simple_channel_panel_frame.dart';
import 'package:clubtivi/features/channels/simple_channel_panel_header.dart';
import 'package:clubtivi/features/channels/simple_home_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 10, 13, 8, 30);
final _programmes = List.generate(
  3,
  (i) => db.EpgProgramme(
    id: i,
    epgChannelId: 'cctv6',
    sourceId: 'test',
    title: ['光影星播客', '电影频道特别节目', '今日影评'][i],
    start: DateTime(2026, 10, 13, 8 + i),
    stop: DateTime(2026, 10, 13, 9 + i),
  ),
);

List<CompactCategoryOption> _options(int level, {ValueChanged<int>? onTap}) =>
    List.generate(
      40,
      (i) => CompactCategoryOption(
        id: '$i',
        label: i == 39 ? ['中国', '地方台', '上海'][level - 1] : '分类 $i',
        selected: i == 39,
        onTap: () => onTap?.call(i),
      ),
    );

Future<void> _pumpBrowser(
  WidgetTester tester,
  Size size, {
  double textScale = 1,
  bool preview = false,
}) async {
  final tiny = size.height <= 450;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        textTheme: ThemeData.dark().textTheme.apply(
          fontFamily: preview ? 'BobTVCompactPreview' : null,
        ),
      ),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          backgroundColor: const Color(0xFF101A2C),
          body: RepaintBoundary(
            key: const ValueKey('compact-preview'),
            child: Column(
              children: [
                const SizedBox(
                  height: 52,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: EdgeInsets.only(right: 16),
                      child: Text('退出 BobTV'),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: AdaptiveHomeToolbar(
                    compact: true,
                    brand: const Text(
                      'BobTV',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    actions: [
                      IconButton(
                        constraints: tiny
                            ? const BoxConstraints.tightFor(
                                width: 40,
                                height: 40,
                              )
                            : null,
                        style: tiny
                            ? IconButton.styleFrom(
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              )
                            : null,
                        onPressed: () {},
                        icon: const Icon(Icons.settings_outlined),
                      ),
                      IconButton(
                        constraints: tiny
                            ? const BoxConstraints.tightFor(
                                width: 40,
                                height: 40,
                              )
                            : null,
                        style: tiny
                            ? IconButton.styleFrom(
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              )
                            : null,
                        onPressed: () {},
                        icon: const Icon(Icons.more_horiz),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SimpleHomeContent(
                    compact: true,
                    preview: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF17283E),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white24),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        children: [
                          const Expanded(
                            child: ColoredBox(
                              color: Colors.black,
                              child: Center(
                                child: Icon(
                                  Icons.live_tv,
                                  size: 44,
                                  color: Colors.white30,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'CCTV-6 电影',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    channels: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF17283E),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: SimpleChannelPanelFrame(
                        compact: true,
                        onSearch: () {},
                        header: const SimpleChannelPanelHeader(
                          compact: true,
                          syncBadge: SizedBox(
                            width: 62,
                            height: 22,
                            child: Center(
                              child: Text(
                                '已同步',
                                style: TextStyle(fontSize: 11),
                              ),
                            ),
                          ),
                          summary: '8 个频道',
                        ),
                        navigation: Column(
                          children: [
                            for (var level = 1; level <= 3; level++) ...[
                              if (level > 1) const SizedBox(height: 3),
                              CompactCategoryRow(
                                tiny: tiny,
                                level: level,
                                title: '第 $level 级分类',
                                options: _options(level),
                              ),
                            ],
                          ],
                        ),
                        search: const TextField(
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            hintText: '搜索当前分类',
                            prefixIconConstraints: BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            prefixIcon: Icon(Icons.search, size: 18),
                          ),
                          style: TextStyle(fontSize: 12),
                        ),
                        body: LayoutBuilder(
                          builder: (context, constraints) {
                            final singleLine = constraints.maxHeight < 230;
                            final guideHeight =
                                ChannelProgrammeStrip.compactHeight(
                                  MediaQuery.textScalerOf(context),
                                  singleLine: singleLine,
                                  dense: tiny,
                                );
                            return InlineExpandedChannelGrid(
                              channelIds: const [
                                'cctv6',
                                'cctv1',
                                'cctv5',
                                'cctv9',
                              ],
                              columns: TabletPresentation.channelColumns(
                                constraints.maxWidth,
                                compact: true,
                                tiny: tiny,
                              ),
                              cardHeight: TabletPresentation.compactCardHeight(
                                constraints.maxHeight,
                                guideHeight,
                                tiny: tiny,
                              ),
                              spacing: 8,
                              guideGap: tiny ? 4 : 6,
                              padding: tiny
                                  ? const EdgeInsets.fromLTRB(4, 2, 4, 4)
                                  : const EdgeInsets.fromLTRB(4, 4, 4, 8),
                              expandedChannelId: 'cctv6',
                              expandedContent: ChannelProgrammeStrip(
                                channelName: 'CCTV-6',
                                programmes: _programmes,
                                now: _now,
                                embedded: true,
                                showHeader: false,
                                compact: true,
                                compactSingleLine: singleLine,
                                compactDense: tiny,
                              ),
                              cardBuilder: (_, i) => Container(
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFF405E87),
                                      Color(0xFF111E32),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(19),
                                ),
                                padding: EdgeInsets.all(tiny ? 6 : 9),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      '● 静音预览',
                                      style: TextStyle(fontSize: tiny ? 8 : 9),
                                    ),
                                    const Spacer(),
                                    Text(
                                      [
                                        'CCTV-6 电影',
                                        'CCTV-1 综合',
                                        'CCTV-5 体育',
                                        'CCTV-9 纪录',
                                      ][i],
                                      maxLines: 1,
                                      style: TextStyle(
                                        fontSize: tiny ? 13 : 16,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    SizedBox(height: tiny ? 2 : 4),
                                    Text(
                                      '点击切换到主画面',
                                      style: TextStyle(fontSize: tiny ? 8 : 9),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [
    const Size(640, 360),
    const Size(800, 400),
    const Size(960, 400),
    const Size(640, 480),
    const Size(800, 480),
    const Size(800, 600),
    const Size(960, 540),
    const Size(1024, 600),
    const Size(1024, 768),
    const Size(1280, 720),
    const Size(1280, 1024),
    const Size(800, 1280),
    const Size(600, 960),
    const Size(360, 640),
  ]) {
    testWidgets(
      '$size reserves a complete card and its EPG with only three category rows',
      (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await _pumpBrowser(tester, size);
        expect(tester.takeException(), isNull);
        for (var level = 1; level <= 3; level++) {
          expect(
            tester
                .getSize(find.byKey(ValueKey('category-level-$level')))
                .height,
            closeTo(size.height <= 450 ? 24 : 32, .01),
          );
          expect(
            find.byKey(ValueKey('row-category-$level-39')),
            findsOneWidget,
          );
        }
        if (size.width >= 640) {
          final main = tester.getRect(
            find.byKey(const ValueKey('simple-main-pane')),
          );
          final channels = tester.getRect(
            find.byKey(const ValueKey('simple-channel-pane')),
          );
          expect(main.width, lessThanOrEqualTo(size.width / 2));
          expect(main.width, closeTo(channels.width, .01));
        }
        final list = tester.getRect(find.byType(InlineExpandedChannelGrid));
        final card = tester.getRect(
          find.byKey(const ValueKey('grid-card-cctv6')),
        );
        final epg = tester.getRect(
          find.byKey(const ValueKey('channel-programme-strip')),
        );
        expect(card.top, greaterThanOrEqualTo(list.top));
        expect(epg.bottom, lessThanOrEqualTo(list.bottom + .01));
        expect(epg.height, greaterThan(size.height <= 450 ? 50 : 70));
        expect(card.height, greaterThanOrEqualTo(size.height <= 450 ? 56 : 80));
        expect(TabletPresentation.videoFit, BoxFit.contain);
      },
    );
  }

  testWidgets(
    'larger accessibility fonts retain full preview and guide at 800x600',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpBrowser(tester, const Size(800, 600), textScale: 1.5);
      expect(tester.takeException(), isNull);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('channel-programme-strip')))
            .bottom,
        lessThanOrEqualTo(
          tester.getRect(find.byType(InlineExpandedChannelGrid)).bottom,
        ),
      );
    },
  );

  for (var level = 1; level <= 3; level++) {
    testWidgets(
      'level $level menu joins its button and includes every option',
      (tester) async {
        var chosen = -1;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: SizedBox(
                  width: 280,
                  child: CompactCategoryRow(
                    level: level,
                    title: '分类',
                    options: _options(level, onTap: (i) => chosen = i),
                  ),
                ),
              ),
            ),
          ),
        );
        final button = find.byKey(ValueKey('category-more-$level'));
        final anchor = tester.getRect(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        final menu = tester.getRect(
          find.byKey(ValueKey('category-menu-$level')),
        );
        expect(menu.top, closeTo(anchor.bottom, .01));
        expect(menu.right, closeTo(anchor.right, .01));
        expect(find.byKey(ValueKey('menu-category-$level-0')), findsOneWidget);
        final last = find.byKey(ValueKey('menu-category-$level-39'));
        await tester.ensureVisible(last);
        await tester.tap(last);
        await tester.pumpAndSettle();
        expect(chosen, 39);
        expect(find.byKey(ValueKey('category-menu-$level')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a menu near the bottom opens upwards without leaving the screen',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: 280,
                  child: CompactCategoryRow(
                    level: 3,
                    title: '地区',
                    options: _options(3),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final button = find.byKey(const ValueKey('category-more-3'));
      final anchor = tester.getRect(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      final menu = tester.getRect(
        find.byKey(const ValueKey('category-menu-3')),
      );
      expect(menu.bottom, closeTo(anchor.top, .01));
      expect(menu.top, greaterThanOrEqualTo(0));
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('category-menu-3')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  test('compact joined outlines exclude adjacent cards at every column', () {
    for (final height in [80.0, 100.0, 140.0]) {
      for (var columns = 1; columns <= 3; columns++) {
        for (var selected = 0; selected < columns; selected++) {
          final outline = ChannelGuideOutline(
            column: selected,
            columns: columns,
            cardHeight: height,
            guideGap: 6,
            spacing: 8,
          );
          final path = outline.outline(Size(600, height + 6 + 83));
          final width = (600 - (columns - 1) * 8) / columns;
          for (var i = 0; i < columns; i++) {
            expect(
              path.contains(Offset(i * (width + 8) + width / 2, 40)),
              i == selected,
            );
          }
          expect(path.contains(Offset(300, height + 45)), isTrue);
          expect(path.computeMetrics().length, 1);
        }
      }
    }
  });

  testWidgets('an overflowing selected label cannot push more offscreen', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 160,
            child: CompactCategoryRow(
              level: 1,
              title: '主分类',
              options: [
                CompactCategoryOption(
                  id: 'long',
                  label: '这是一个很长的自定义分类名称',
                  selected: true,
                  onTap: () {},
                ),
                CompactCategoryOption(
                  id: 'other',
                  label: '其他',
                  selected: false,
                  onTap: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('category-more-1')), findsOneWidget);
  });

  testWidgets(
    'local visual previews',
    (tester) async {
      await tester.runAsync(() async {
        final loader = FontLoader('BobTVCompactPreview');
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
      for (final size in [
        const Size(640, 360),
        const Size(800, 480),
        const Size(1024, 600),
        const Size(1280, 720),
      ]) {
        await _pumpBrowser(tester, size, preview: true);
        await expectLater(
          find.byKey(const ValueKey('compact-preview')),
          matchesGoldenFile(
            '/tmp/bobtv-compact-${size.width.toInt()}x${size.height.toInt()}.png',
          ),
        );
        await tester.tap(find.byKey(const ValueKey('category-more-3')));
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            '/tmp/bobtv-compact-menu-${size.width.toInt()}x${size.height.toInt()}.png',
          ),
        );
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
    skip: !const bool.fromEnvironment('BOBTV_COMPACT_PREVIEW'),
  );
}
