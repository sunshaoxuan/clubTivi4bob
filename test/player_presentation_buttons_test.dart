import 'package:clubtivi/features/player/player_presentation_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final compact in [false, true]) {
    testWidgets(
      'independent window and fullscreen controls, compact=$compact',
      (tester) async {
        var windowRequests = 0;
        var fullscreenRequests = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  const Expanded(child: Text('Astro 爱奇艺', maxLines: 1)),
                  PlayerPresentationButtons(
                    compact: compact,
                    showWindowPin: true,
                    onWindowPlayback: () => windowRequests++,
                    onFullscreen: () => fullscreenRequests++,
                  ),
                ],
              ),
            ),
          ),
        );
        final window = find.byTooltip('全窗口播放');
        final fullscreen = find.byTooltip('全屏播放');
        expect(find.byTooltip('窗口置顶'), findsOneWidget);
        expect(
          tester.getRect(find.byTooltip('窗口置顶')).right,
          lessThanOrEqualTo(tester.getRect(window).left),
        );
        expect(
          tester.getRect(window).right,
          lessThanOrEqualTo(tester.getRect(fullscreen).left),
        );
        await tester.tap(window);
        expect(windowRequests, 1);
        expect(fullscreenRequests, 0);
        await tester.tap(fullscreen);
        expect(windowRequests, 1);
        expect(fullscreenRequests, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('mobile retains the original fullscreen action alone', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PlayerPresentationButtons(onFullscreen: () {})),
      ),
    );
    expect(find.byTooltip('全窗口播放'), findsNothing);
    expect(find.byTooltip('窗口置顶'), findsNothing);
    expect(find.byTooltip('全屏播放'), findsOneWidget);
  });

  testWidgets('window buttons fit narrow footers at large text scales', (
    tester,
  ) async {
    for (final width in [240.0, 320.0, 460.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: MediaQuery(
                  data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '正在播放 Astro 爱奇艺',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        onPressed: () {},
                        icon: const Icon(Icons.star),
                      ),
                      PlayerPresentationButtons(
                        showWindowPin: true,
                        onWindowPlayback: () {},
                        onFullscreen: () {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byTooltip('全窗口播放'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
