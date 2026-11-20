import 'package:clubtivi/features/player/player_channel_drawer_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(834, 1194),
  ]) {
    testWidgets('fullscreen channels fit and follow direction at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: Scaffold(
            body: Stack(
              children: const [
                Positioned.fill(
                  child: ColoredBox(
                    key: ValueKey('video'),
                    color: Colors.black,
                  ),
                ),
                PlayerChannelDrawerFrame(
                  child: ColoredBox(
                    key: ValueKey('channels'),
                    color: Colors.blue,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byKey(const ValueKey('channels')));
      expect(rect.right, size.width);
      expect(rect.bottom, size.height);
      if (size.height > size.width) {
        expect(rect.width, size.width);
        expect(rect.height, closeTo(size.height * .68, .01));
      } else {
        expect(rect.left, greaterThan(0));
        expect(rect.height, size.height);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
