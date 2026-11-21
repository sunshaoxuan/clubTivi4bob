import 'package:clubtivi/features/player/player_toolbar_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'bottom navigation remains usable after playback actions hide',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var returns = 0;
      final back = find.byIcon(Icons.arrow_back);
      final exit = find.byTooltip('退出 BobTV');
      for (final width in [1000.0, 320.0, 260.0]) {
        Offset? backCenter;
        for (final showControls in [true, false]) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomLeft,
                  child: SizedBox(
                    width: width,
                    child: PlayerToolbarActions(
                      onBack: () => returns++,
                      showExit: true,
                      playbackActions: showControls
                          ? List.generate(
                              14,
                              (_) => const SizedBox(
                                width: 38,
                                height: 40,
                                child: Icon(Icons.settings),
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(back, findsOneWidget);
          expect(exit, findsOneWidget);
          final center = tester.getCenter(back);
          if (backCenter != null) expect(center, backCenter);
          backCenter = center;
          expect(
            tester.getRect(back).right,
            lessThan(tester.getRect(exit).left),
          );
          expect(
            find.byIcon(Icons.settings),
            showControls ? findsNWidgets(14) : findsNothing,
          );
          await tester.tap(back);
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
      }
      expect(returns, 6);
    },
    skip: !const bool.fromEnvironment('dart.library.io'),
  );
}
