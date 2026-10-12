import 'package:clubtivi/data/services/manual_channel_category.dart';
import 'package:clubtivi/features/channels/channel_category_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openPicker(
  WidgetTester tester, {
  ValueChanged<ChannelCategoryDestination?>? onResult,
  List<String> existingGroups = const [],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final result = await showDialog<ChannelCategoryDestination>(
                context: context,
                builder: (_) => ChannelCategoryPicker(
                  channelName: '测试频道',
                  existingGroups: existingGroups,
                ),
              );
              onResult?.call(result);
            },
            child: const Text('打开选择器'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开选择器'));
  await tester.pumpAndSettle();
}

OutlinedButton option(WidgetTester tester, String label) =>
    tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, label));

void main() {
  testWidgets(
    'input creates a missing country and continues into custom subcategories',
    (tester) async {
      ChannelCategoryDestination? selected;
      await openPicker(tester, onResult: (value) => selected = value);
      for (final name in ['科威特', '自然科学', '生态']) {
        await tester.enterText(find.byType(TextField), name);
        await tester.pumpAndSettle();
        expect(find.text('创建“$name”'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('category-create')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
      }
      expect(find.text('科威特 / 自然科学 / 生态'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '应用分类'));
      await tester.pumpAndSettle();
      expect(selected!.path, ['科威特', '自然科学', '生态']);
      expect(selected!.group, '国际 / 科威特 / 自然科学 / 生态');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saved custom countries and children are selectable after reopening',
    (tester) async {
      await openPicker(
        tester,
        existingGroups: ['国际 / 科威特 / 自然科学 / 生态', '中国 / 文化 / 戏曲'],
      );
      option(tester, '科威特').onPressed!();
      await tester.pumpAndSettle();
      option(tester, '自然科学').onPressed!();
      await tester.pumpAndSettle();
      option(tester, '生态').onPressed!();
      await tester.pumpAndSettle();
      expect(find.text('科威特 / 自然科学 / 生态'), findsOneWidget);
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '全部地区'))
          .onPressed!();
      await tester.pumpAndSettle();
      option(tester, '中国').onPressed!();
      await tester.pumpAndSettle();
      option(tester, '文化').onPressed!();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, '戏曲'), findsOneWidget);
    },
  );

  testWidgets(
    'normalized existing input reuses one option and return selects it',
    (tester) async {
      await openPicker(tester, existingGroups: ['国际 / 科威特 / Science']);
      option(tester, '科威特').onPressed!();
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  science  ');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('category-create')), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Science'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('科威特 / Science'), findsOneWidget);
    },
  );

  testWidgets('invalid input cannot create or accidentally apply the parent', (
    tester,
  ) async {
    await openPicker(tester);
    option(tester, '美国').onPressed!();
    await tester.pumpAndSettle();
    for (final name in ['A/B', r'A\B', '字' * 49, '全部']) {
      await tester.enterText(find.byType(TextField), name);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('category-create')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '应用分类'))
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.errorText,
        isNotNull,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('美国'), findsNWidgets(2));
    }
    await tester.tap(find.byTooltip('清空输入'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '应用分类'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'repeated create callbacks and old callbacks cannot duplicate paths',
    (tester) async {
      await openPicker(tester);
      await tester.enterText(find.byType(TextField), '科威特');
      await tester.pumpAndSettle();
      final create = tester
          .widget<FilledButton>(find.byKey(const ValueKey('category-create')))
          .onPressed!;
      for (var i = 0; i < 8; i++) {
        create();
      }
      await tester.pumpAndSettle();
      expect(find.text('科威特'), findsNWidgets(2)); // breadcrumb and path summary
      expect(find.textContaining('科威特 / 科威特'), findsNothing);
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '全部地区'))
          .onPressed!();
      create();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, '中国'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '科威特'), findsOneWidget);
    },
  );

  testWidgets('canceling a draft creation does not return a destination', (
    tester,
  ) async {
    ChannelCategoryDestination? selected;
    var results = 0;
    await openPicker(
      tester,
      onResult: (value) {
        selected = value;
        results++;
      },
    );
    await tester.enterText(find.byType(TextField), '科威特');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('category-create')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(results, 1);
    expect(selected, isNull);
  });

  for (final size in [
    const Size(360, 640),
    const Size(640, 480),
    const Size(900, 700),
  ]) {
    testWidgets('creation remains usable at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await openPicker(tester);
      for (final name in ['科威特', '自然科学', '生态']) {
        await tester.enterText(find.byType(TextField), name);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('category-create')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.enterText(find.byType(TextField), '字' * 48);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('category-create')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('queued option callbacks are harmless after outside dismissal', (
    tester,
  ) async {
    await openPicker(tester);
    final stale = option(tester, '中国').onPressed!;
    Navigator.of(tester.element(find.byType(ChannelCategoryPicker))).pop();
    await tester.pumpAndSettle();
    stale();
    expect(tester.takeException(), isNull);
    expect(find.text('打开选择器'), findsOneWidget);
  });
  testWidgets(
    'rapid repeated callbacks advance only one level before repaint',
    (tester) async {
      await openPicker(tester);
      for (final label in ['中国', '地方', '北京']) {
        final staleCallback = option(tester, label).onPressed!;
        for (var press = 0; press < 6; press++) {
          staleCallback();
        }
        await tester.pumpAndSettle();
      }
      expect(find.text('中国 / 地方 / 北京'), findsOneWidget);
      expect(find.textContaining('北京 / 北京'), findsNothing);
      expect(find.textContaining('中国 / 中国'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '应用分类'))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'old child and breadcrumb callbacks stay invalid after going back',
    (tester) async {
      await openPicker(tester);
      final china = option(tester, '中国').onPressed!;
      china();
      await tester.pumpAndSettle();
      final region = option(tester, '地方').onPressed!;
      region();
      await tester.pumpAndSettle();
      final beijing = option(tester, '北京').onPressed!;
      final root = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '全部地区'))
          .onPressed!;
      root();
      root();
      beijing();
      region();
      china();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, '中国'), findsOneWidget);
      expect(find.text('中国 / 地方 / 北京'), findsNothing);
      option(tester, '中国').onPressed!();
      await tester.pumpAndSettle();
      option(tester, '地方').onPressed!();
      await tester.pumpAndSettle();
      option(tester, '天津').onPressed!();
      await tester.pumpAndSettle();
      expect(find.text('中国 / 地方 / 天津'), findsOneWidget);
    },
  );

  testWidgets(
    'hover and press have explicit feedback while retaining keyboard focus',
    (tester) async {
      await openPicker(tester);
      final button = option(tester, '中国');
      final normal = button.style!.backgroundColor!.resolve({});
      final hover = button.style!.backgroundColor!.resolve({
        WidgetState.hovered,
      });
      final pressed = button.style!.backgroundColor!.resolve({
        WidgetState.pressed,
      });
      expect(normal, isNot(hover));
      expect(hover, isNot(pressed));
      expect(
        button.style!.side!.resolve({WidgetState.hovered})!.width,
        greaterThan(button.style!.side!.resolve({})!.width),
      );
      expect(
        button.style!.side!.resolve({WidgetState.focused})!.color,
        const Color(0xFFB7D7FF),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getCenter(find.widgetWithText(OutlinedButton, '中国')),
      );
      await tester.pump(const Duration(milliseconds: 120));
      final materials = find.descendant(
        of: find.widgetWithText(OutlinedButton, '中国'),
        matching: find.byType(Material),
      );
      expect(
        tester
            .widgetList<Material>(materials)
            .any((item) => item.color == hover),
        isTrue,
      );
      await mouse.down(
        tester.getCenter(find.widgetWithText(OutlinedButton, '中国')),
      );
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        tester
            .widgetList<Material>(materials)
            .any((item) => item.color == pressed),
        isTrue,
      );
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, '央视'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
    },
  );

  testWidgets(
    'double apply closes only the picker and returns one valid result',
    (tester) async {
      var results = 0;
      ChannelCategoryDestination? selected;
      await openPicker(
        tester,
        onResult: (result) {
          results++;
          selected = result;
        },
      );
      option(tester, '中国').onPressed!();
      await tester.pumpAndSettle();
      option(tester, '央视').onPressed!();
      await tester.pumpAndSettle();
      final apply = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '应用分类'))
          .onPressed!;
      apply();
      apply();
      apply();
      await tester.pumpAndSettle();
      expect(results, 1);
      expect(selected!.path, ['中国', '央视']);
      expect(find.text('打开选择器'), findsOneWidget);
      expect(find.byType(ChannelCategoryPicker), findsNothing);
    },
  );

  testWidgets('a stale apply cannot submit an earlier parent selection', (
    tester,
  ) async {
    await openPicker(tester);
    option(tester, '美国').onPressed!();
    await tester.pumpAndSettle();
    final oldApply = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '应用分类'))
        .onPressed!;
    option(tester, '新闻').onPressed!();
    oldApply();
    await tester.pumpAndSettle();
    expect(find.byType(ChannelCategoryPicker), findsOneWidget);
    expect(find.text('美国 / 新闻'), findsOneWidget);
  });

  testWidgets('a queued apply cannot discard a newly typed category name', (
    tester,
  ) async {
    await openPicker(tester);
    option(tester, '美国').onPressed!();
    await tester.pumpAndSettle();
    final oldApply = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '应用分类'))
        .onPressed!;
    await tester.enterText(find.byType(TextField), '自然科学');
    oldApply();
    await tester.pumpAndSettle();
    expect(find.byType(ChannelCategoryPicker), findsOneWidget);
    expect(find.byKey(const ValueKey('category-create')), findsOneWidget);
  });

  testWidgets('search reports no results and navigation resets the query', (
    tester,
  ) async {
    await openPicker(tester);
    await tester.enterText(find.byType(TextField), 'missing-category-xyz');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的分类'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '中国');
    await tester.pumpAndSettle();
    option(tester, '中国').onPressed!();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(OutlinedButton, '央视'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text ?? '',
      isEmpty,
    );
  });
}
