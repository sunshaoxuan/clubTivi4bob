import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

class _Platform extends Fake implements PlatformVideoController {
  @override
  final rect = ValueNotifier<Rect?>(const Rect.fromLTWH(0, 0, 1920, 1080));
}

class _Video extends Fake implements VideoController {
  _Video(PlatformVideoController platform)
    : notifier = ValueNotifier<PlatformVideoController?>(platform);
  @override
  final ValueNotifier<PlatformVideoController?> notifier;
}

void main() {
  testWidgets('subtitle viewport follows moving surface and decoded aspect', (
    tester,
  ) async {
    final platform = _Platform();
    final controller = _Video(platform);
    final offset = ValueNotifier(const Offset(100, 50));
    const marker = Key('subtitle-picture-region');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<Offset>(
            valueListenable: offset,
            builder: (context, position, _) => Stack(
              children: [
                Positioned(
                  left: position.dx,
                  top: position.dy,
                  width: 400,
                  height: 300,
                  child: VideoSubtitleViewport(
                    controller: controller,
                    child: const ColoredBox(key: marker, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(
      tester.getRect(find.byKey(marker)),
      const Rect.fromLTWH(100, 87.5, 400, 225),
    );
    offset.value = const Offset(400, 300);
    await tester.pump();
    expect(
      tester.getRect(find.byKey(marker)),
      const Rect.fromLTWH(400, 337.5, 400, 225),
    );
    platform.rect.value = const Rect.fromLTWH(0, 0, 640, 480);
    await tester.pump();
    expect(
      tester.getRect(find.byKey(marker)),
      const Rect.fromLTWH(400, 300, 400, 300),
    );
    platform.rect.value = null;
    await tester.pump();
    expect(find.byKey(marker), findsNothing);
    await tester.pumpWidget(const SizedBox());
    offset.dispose();
    platform.rect.dispose();
    controller.notifier.dispose();
  });
}
