import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/app/theme.dart';
import 'package:clubtivi/features/channels/mobile_channel_home.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    Future<bool> Function(String)? select,
    Future<void> Function(String, String)? category,
    double scale = 1,
    String? currentId,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ClubTiviTheme.dark,
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
          ),
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            body: MobileChannelHome(
              currentId: currentId,
              video: const ColoredBox(
                key: ValueKey('video'),
                color: Colors.black,
              ),
              channels: List.generate(
                40,
                (i) => MobileChannelItem(
                  id: '$i',
                  name: '频道 $i',
                  sourceId: i.isEven ? 'a' : 'b',
                  favorite: i.isEven,
                ),
              ),
              sources: const {'a': '来源 A', 'b': '来源 B'},
              categories: const ['央视', '纪录片', '国际'],
              category: '央视',
              countries: const ['日本', '法国'],
              onCategory: category ?? (_, _) async {},
              onSelect: select ?? (_) async => true,
              onPause: () {},
              onMute: () {},
              onManageSources: () {},
            ),
          ),
        ),
      ),
    );
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('mobile-open-channels')));
    await tester.pumpAndSettle();
  }

  test('phone policy keeps tablet and desktop layouts', () {
    expect(
      useMobileChannelHome(
        platform: TargetPlatform.iOS,
        size: const Size(390, 844),
      ),
      isTrue,
    );
    expect(
      useMobileChannelHome(
        platform: TargetPlatform.android,
        size: const Size(844, 390),
      ),
      isTrue,
    );
    expect(
      useMobileChannelHome(
        platform: TargetPlatform.iOS,
        size: const Size(1024, 768),
      ),
      isFalse,
    );
    expect(
      useMobileChannelHome(
        platform: TargetPlatform.macOS,
        size: const Size(390, 844),
      ),
      isFalse,
    );
    expect(
      useMobileChannelHome(
        platform: TargetPlatform.android,
        size: const Size(390, 844),
        television: true,
      ),
      isFalse,
    );
  });
  testWidgets(
    'portrait opens bottom, landscape opens right without replacing video',
    (tester) async {
      await mount(tester);
      final video = tester.element(find.byKey(const ValueKey('video')));
      await open(tester);
      final bottom = find.byKey(const ValueKey('mobile-bottom-drawer'));
      expect(tester.getRect(bottom).bottom, 844);
      expect(tester.getRect(bottom).width, 390);
      expect(tester.getRect(bottom).top, greaterThan(100));
      expect(tester.element(find.byKey(const ValueKey('video'))), same(video));
      await tester.tap(find.byKey(const ValueKey('mobile-close-drawer')));
      await tester.pumpAndSettle();
      await mount(tester, size: const Size(844, 390));
      await open(tester);
      final right = find.byKey(const ValueKey('mobile-right-drawer'));
      expect(tester.getRect(right).right, 844);
      expect(tester.getRect(right).height, 390);
      final grid = tester.widget<GridView>(find.byType(GridView));
      expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        2,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failed selection stays open, success closes; scroll position is retained',
    (tester) async {
      var ready = false;
      await mount(tester, select: (_) async => ready);
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('mobile-channel-0')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile-bottom-drawer')),
        findsOneWidget,
      );
      await tester.drag(find.byType(GridView), const Offset(0, -250));
      await tester.pumpAndSettle();
      final before = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(GridView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position
          .pixels;
      await tester.tap(find.byKey(const ValueKey('mobile-close-drawer')));
      await tester.pumpAndSettle();
      await open(tester);
      final after = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(GridView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position
          .pixels;
      expect(after, before);
      ready = true;
      await tester.drag(find.byType(GridView), const Offset(0, 1000));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mobile-channel-0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mobile-bottom-drawer')), findsNothing);
    },
  );
  testWidgets('stopped current channel can retry without premature dismissal', (
    tester,
  ) async {
    var attempts = 0;
    await mount(
      tester,
      currentId: '0',
      select: (_) async {
        attempts++;
        return attempts > 1;
      },
    );
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('mobile-channel-0')));
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(find.byKey(const ValueKey('mobile-bottom-drawer')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mobile-channel-0')));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.byKey(const ValueKey('mobile-bottom-drawer')), findsNothing);
  });
  testWidgets('filter draft does not play or apply until confirmation', (
    tester,
  ) async {
    var applied = '';
    var selected = 0;
    await mount(
      tester,
      category: (group, _) async {
        applied = group;
      },
      select: (_) async {
        selected++;
        return true;
      },
    );
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('mobile-open-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, '纪录片'));
    await tester.pumpAndSettle();
    expect(applied, isEmpty);
    expect(selected, 0);
    await tester.tap(find.byKey(const ValueKey('mobile-apply-filter')));
    await tester.pumpAndSettle();
    expect(applied, '纪录片');
    expect(selected, 0);
    expect(find.byType(GridView), findsOneWidget);
  });
  testWidgets('large text uses one column without overflow', (tester) async {
    await mount(tester, size: const Size(320, 700), scale: 1.6);
    await open(tester);
    final grid = tester.widget<GridView>(find.byType(GridView));
    expect(
      (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      1,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('mobile-open-filter')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('old success cannot close drawer for a newer failed selection', (
    tester,
  ) async {
    final first = Completer<bool>();
    await mount(
      tester,
      select: (id) => id == '0' ? first.future : Future.value(false),
    );
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('mobile-channel-0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('mobile-channel-1')));
    await tester.pumpAndSettle();
    first.complete(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-bottom-drawer')), findsOneWidget);
    expect(find.text('失败，请重试'), findsOneWidget);
  });
  testWidgets('search filters visible channels without starting playback', (
    tester,
  ) async {
    var plays = 0;
    await mount(
      tester,
      select: (_) async {
        plays++;
        return true;
      },
    );
    await open(tester);
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mobile-search-field')),
      '频道 39',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-channel-39')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-channel-0')), findsNothing);
    expect(plays, 0);
    await tester.enterText(
      find.byKey(const ValueKey('mobile-search-field')),
      'no-results',
    );
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的频道'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('open drawer changes orientation while retaining filter draft', (
    tester,
  ) async {
    await mount(tester);
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('mobile-open-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, '纪录片'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-right-drawer')), findsOneWidget);
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, '纪录片'))
          .selected,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}
