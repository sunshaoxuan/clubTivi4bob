import 'dart:io';

import 'package:clubtivi/features/channels/compact_category_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _provinces = [
  '北京',
  '天津',
  '上海',
  '重庆',
  '河北',
  '山西',
  '辽宁',
  '吉林',
  '黑龙江',
  '江苏',
  '浙江',
  '安徽',
  '福建',
  '江西',
  '山东',
  '河南',
  '湖北',
  '湖南',
  '广东',
  '海南',
  '四川',
  '贵州',
  '云南',
  '陕西',
  '甘肃',
  '青海',
  '内蒙古',
  '广西',
  '西藏',
  '宁夏',
  '新疆',
];

Future<void> _openMenu(
  WidgetTester tester, {
  Size size = const Size(520, 540),
  double width = 458,
  double textScale = 1,
  List<String> labels = _provinces,
  TargetPlatform platform = TargetPlatform.windows,
  ValueChanged<String>? onSelected,
  bool preview = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        platform: platform,
        textTheme: ThemeData.dark().textTheme.apply(
          fontFamily: preview ? 'BobTVCategoryPreview' : null,
        ),
      ),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          backgroundColor: const Color(0xFF111C2C),
          body: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 100, right: 16),
              child: SizedBox(
                width: width,
                child: CompactCategoryRow(
                  level: 3,
                  title: '地区',
                  options: [
                    for (final label in labels)
                      CompactCategoryOption(
                        id: label,
                        label: label,
                        selected: label == '上海',
                        onTap: () => onSelected?.call(label),
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
  await tester.tap(find.byKey(const ValueKey('category-more-3')));
  await tester.pumpAndSettle();
}

void main() {
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    testWidgets(
      'roomy ${platform.name} menu enlarges controls and fits choices',
      (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await _openMenu(tester, platform: platform);
        final menu = find.byKey(const ValueKey('category-menu-3'));
        final first = find.byKey(const ValueKey('menu-category-3-北京'));
        final last = find.byKey(const ValueKey('menu-category-3-新疆'));
        final label = tester.widget<Text>(
          find.descendant(of: first, matching: find.text('北京')),
        );
        expect(label.style!.fontSize, greaterThanOrEqualTo(15));
        expect(tester.getSize(first).height, greaterThanOrEqualTo(44));
        expect(last.hitTestable(), findsOneWidget);
        expect(
          tester.getRect(menu).bottom - tester.getRect(last).bottom,
          inInclusiveRange(10, 16),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a shorter list uses the largest menu controls without blank space',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _openMenu(tester, labels: _provinces.take(10).toList(), width: 220);
      final first = find.byKey(const ValueKey('menu-category-3-北京'));
      final text = tester.widget<Text>(
        find.descendant(of: first, matching: find.text('北京')),
      );
      expect(text.style!.fontSize, 16);
      expect(tester.getSize(first).height, greaterThanOrEqualTo(48));
      expect(
        tester.getSize(find.byKey(const ValueKey('category-menu-3'))).height,
        lessThan(360),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('small screens and large text keep every choice reachable', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? selected;
    await _openMenu(
      tester,
      size: const Size(320, 360),
      width: 280,
      textScale: 1.8,
      onSelected: (value) => selected = value,
    );
    final menu = tester.getRect(find.byKey(const ValueKey('category-menu-3')));
    expect(menu.bottom, lessThanOrEqualTo(360));
    final last = find.byKey(const ValueKey('menu-category-3-新疆'));
    await tester.ensureVisible(last);
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(selected, '新疆');
    expect(find.byKey(const ValueKey('category-menu-3')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'local enlarged category preview',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final font = FontLoader('BobTVCategoryPreview');
        font.addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '/System/Library/Fonts/STHeiti Light.ttc',
              ).readAsBytes(),
            ),
          ),
        );
        await font.load();
        final icons = FontLoader('MaterialIcons');
        icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });
      await _openMenu(tester, preview: true);
      await expectLater(
        find.byKey(const ValueKey('category-menu-surface-3')),
        matchesGoldenFile('/tmp/bobtv-category-menu-enlarged.png'),
      );
    },
    skip: !const bool.fromEnvironment('BOBTV_CATEGORY_PREVIEW'),
  );
}
