import 'package:clubtivi/features/channels/touch_action_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'touch actions close before navigation and fit small landscape screens',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(568, 320);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      var selected = false;
      var sheetClosed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showTouchActionSheet(
                  context,
                  title: '播放功能',
                  actions: [
                    const TouchAction('disabled', '不可用操作', Icons.block, null),
                    for (var i = 0; i < 12; i++)
                      TouchAction('$i', '频道操作 $i', Icons.tune, () {
                        selected = true;
                        sheetClosed = !Navigator.of(context).canPop();
                      }),
                  ],
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('touch-action-disabled')));
      await tester.pumpAndSettle();
      expect(selected, isFalse);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('touch-action-11')),
        160,
      );
      await tester.tap(find.byKey(const ValueKey('touch-action-11')));
      await tester.pumpAndSettle();
      expect(selected, isTrue);
      expect(sheetClosed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
