import 'package:clubtivi/data/services/country_names.dart';
import 'package:clubtivi/features/channels/compact_category_row.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openCountries(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  double textScale = 1,
  ValueChanged<String>? selected,
  ValueChanged<String>? contextMenu,
  List<String>? labels,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(visualDensity: VisualDensity.compact),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: SizedBox(
            width: 280,
            child: CompactCategoryRow(
              level: 2,
              title: '国家或地区',
              countryIndex: true,
              options: [
                for (final name
                    in labels ?? CountryNames.byCode.values.toSet().toList())
                  CompactCategoryOption(
                    id: 'id-$name',
                    label: name,
                    selected: name == '美国',
                    onTap: () => selected?.call('id-$name'),
                    onContextMenu: (offset) => contextMenu?.call('id-$name'),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  if (labels != null && labels.isEmpty) return;
  await tester.tap(find.byKey(const ValueKey('category-more-2')));
  await tester.pumpAndSettle();
}

Finder country(String name) => find.byKey(ValueKey('menu-category-2-id-$name'));

void main() {
  testWidgets('initial filter keeps IDs and selects exactly once', (
    tester,
  ) async {
    final calls = <String>[];
    await openCountries(tester, selected: calls.add);
    for (final label in ['all', 'A', 'M', 'Z']) {
      expect(
        tester.getSize(find.byKey(ValueKey('country-initial-$label'))).height,
        greaterThanOrEqualTo(44),
      );
      expect(
        tester.getSize(find.byKey(ValueKey('country-initial-$label'))).width,
        greaterThanOrEqualTo(44),
      );
    }
    expect(
      tester.getSize(find.byKey(const ValueKey('country-search'))).height,
      greaterThanOrEqualTo(44),
    );
    await tester.tap(find.byKey(const ValueKey('country-initial-M')));
    await tester.pumpAndSettle();
    expect(country('美国'), findsOneWidget);
    expect(country('加拿大'), findsNothing);
    expect(calls, isEmpty);
    await tester.ensureVisible(country('美国'));
    await tester.tap(country('美国'));
    await tester.pumpAndSettle();
    expect(calls, ['id-美国']);
    expect(find.byKey(const ValueKey('category-menu-2')), findsNothing);
  });

  testWidgets('search, no results, clear and reopen reset only navigation', (
    tester,
  ) async {
    await openCountries(tester);
    final search = find.byKey(const ValueKey('country-search'));
    await tester.enterText(search, 'United States');
    await tester.pumpAndSettle();
    expect(country('美国'), findsOneWidget);
    expect(country('英国'), findsNothing);
    await tester.enterText(search, '没有这个国家');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的国家或地区'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('country-search-clear')));
    await tester.pumpAndSettle();
    expect(country('英国'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('country-initial-Y')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('country-menu-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('category-more-2')));
    await tester.pumpAndSettle();
    expect(country('美国'), findsOneWidget);
    expect(tester.widget<TextField>(search).controller!.text, isEmpty);
  });

  testWidgets('search results preserve secondary click and long press', (
    tester,
  ) async {
    final calls = <String>[];
    await openCountries(tester, contextMenu: calls.add);
    await tester.enterText(find.byKey(const ValueKey('country-search')), '美国');
    await tester.pumpAndSettle();
    await tester.tap(country('美国'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.longPress(country('美国'));
    await tester.pumpAndSettle();
    expect(calls, ['id-美国', 'id-美国']);
    expect(find.byKey(const ValueKey('category-menu-2')), findsOneWidget);
  });

  for (final size in [
    const Size(390, 844),
    const Size(320, 700),
    const Size(320, 360),
  ]) {
    testWidgets('viewport $size keeps menu and long names accessible', (
      tester,
    ) async {
      await openCountries(
        tester,
        size: size,
        textScale: size.height == 360 ? 1.8 : 1,
      );
      final menu = tester.getRect(
        find.byKey(const ValueKey('category-menu-2')),
      );
      expect(menu.left, greaterThanOrEqualTo(12));
      expect(menu.right, lessThanOrEqualTo(size.width - 12));
      expect(menu.top, greaterThanOrEqualTo(12));
      expect(menu.bottom, lessThanOrEqualTo(size.height - 12));
      final search = find.byKey(const ValueKey('country-search'));
      await tester.enterText(search, '圣文森特和格林纳丁斯');
      await tester.pumpAndSettle();
      final target = country('圣文森特和格林纳丁斯');
      await tester.ensureVisible(target);
      expect(target.hitTestable(), findsOneWidget);
      expect(tester.getSize(target).height, greaterThanOrEqualTo(44));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'short window can reach the last letter in the horizontal index',
    (tester) async {
      await openCountries(tester, size: const Size(320, 360), textScale: 1.8);
      final lastLetter = find.byKey(const ValueKey('country-initial-Z'));
      await tester.ensureVisible(lastLetter);
      await tester.pumpAndSettle();
      await tester.tap(lastLetter);
      await tester.pumpAndSettle();
      expect(country('智利'), findsOneWidget);
      expect(country('美国'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keyboard insets resize open menu and keep search results usable',
    (tester) async {
      await openCountries(tester, size: const Size(390, 844));
      addTearDown(tester.view.resetViewInsets);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('country-search')),
        '美国',
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('category-menu-2'))).bottom,
        lessThanOrEqualTo(844 - 300 - 12),
      );
      expect(country('美国').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'index includes special labels and does not select while filtering',
    (tester) async {
      final calls = <String>[];
      await openCountries(
        tester,
        selected: calls.add,
        labels: ['美国', 'United States', '未知国家', '🌍', '123', '香港', '澳门', '台湾'],
      );
      await tester.tap(find.byKey(const ValueKey('country-initial-#')));
      await tester.pumpAndSettle();
      expect(country('🌍'), findsOneWidget);
      expect(country('美国'), findsNothing);
      expect(calls, isEmpty);
    },
  );

  testWidgets('short window with keyboard scrolls controls and results', (
    tester,
  ) async {
    await openCountries(tester, size: const Size(320, 360), textScale: 1.8);
    addTearDown(tester.view.resetViewInsets);
    tester.view.viewInsets = const FakeViewPadding(bottom: 180);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('country-search')), '美国');
    await tester.pumpAndSettle();
    await tester.ensureVisible(country('美国'));
    await tester.pumpAndSettle();
    expect(country('美国').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty country catalog keeps the navigation row hidden', (
    tester,
  ) async {
    await openCountries(tester, labels: []);
    expect(find.byKey(const ValueKey('category-more-2')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard layout switches preserve active search and selection', (
    tester,
  ) async {
    await openCountries(tester, size: const Size(320, 420));
    final search = find.byKey(const ValueKey('country-search'));
    await tester.enterText(search, '美国');
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(search);
    field.controller!.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 1,
    );
    final editable = find.descendant(
      of: search,
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isTrue);
    addTearDown(tester.view.resetViewInsets);
    for (final bottom in [180.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: bottom);
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isTrue);
      expect(
        field.controller!.selection,
        const TextSelection(baseOffset: 0, extentOffset: 1),
      );
      expect(tester.testTextInput.isVisible, isTrue);
    }
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '英国',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pumpAndSettle();
    expect(country('英国'), findsOneWidget);
    expect(country('美国'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
