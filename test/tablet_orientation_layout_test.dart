import 'package:clubtivi/features/channels/simple_home_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> mount(
    WidgetTester tester,
    Size size,
    TargetPlatform platform,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: MediaQuery(
          data: MediaQueryData(size: size),
          child: const Scaffold(
            body: Column(
              children: [
                SizedBox(height: 80),
                Expanded(
                  child: SimpleHomeContent(
                    preview: _VideoProbe(key: ValueKey('video-probe')),
                    channels: ColoredBox(color: Colors.blue),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      '$platform tablet stacks in portrait and keeps video on rotation',
      (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        for (final size in [
          const Size(834, 1194),
          const Size(768, 1024),
          const Size(1024, 1366),
        ]) {
          await mount(tester, size, platform);
          final preview = tester.getRect(
            find.byKey(const ValueKey('simple-main-pane')),
          );
          final channels = tester.getRect(
            find.byKey(const ValueKey('simple-channel-pane')),
          );
          expect(preview.bottom, lessThan(channels.top));
          expect(preview.width, size.width - 20);
          expect(channels.width, preview.width);
          expect(preview.height, lessThan((size.height - 80) * .55));
          expect(tester.takeException(), isNull);
        }
        final state = tester.state(find.byKey(const ValueKey('video-probe')));
        await mount(tester, const Size(1194, 834), platform);
        final preview = tester.getRect(
          find.byKey(const ValueKey('simple-main-pane')),
        );
        final channels = tester.getRect(
          find.byKey(const ValueKey('simple-channel-pane')),
        );
        expect(preview.right, lessThan(channels.left));
        expect(
          tester.state(find.byKey(const ValueKey('video-probe'))),
          same(state),
        );
        await mount(tester, const Size(834, 1194), platform);
        expect(
          tester.state(find.byKey(const ValueKey('video-probe'))),
          same(state),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('desktop portrait window retains its two panes', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, const Size(834, 1194), TargetPlatform.macOS);
    final preview = tester.getRect(
      find.byKey(const ValueKey('simple-main-pane')),
    );
    final channels = tester.getRect(
      find.byKey(const ValueKey('simple-channel-pane')),
    );
    expect(preview.right, lessThan(channels.left));
    expect(tester.takeException(), isNull);
  });
}

class _VideoProbe extends StatefulWidget {
  const _VideoProbe({super.key});
  @override
  State<_VideoProbe> createState() => _VideoProbeState();
}

class _VideoProbeState extends State<_VideoProbe> {
  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}
