import 'package:clubtivi/data/services/website_channel_catalog_service.dart';
import 'package:clubtivi/features/channels/shared_sync_badge.dart';
import 'package:clubtivi/features/channels/simple_channel_panel_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [260.0, 420.0, 784.0, 1200.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('right-aligned status at width $width, text scale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final catalog = ValueNotifier(
          const WebsiteCatalogProgress(complete: true),
        );
        final upload = ValueNotifier(
          const WebsiteCatalogProgress(complete: true),
        );
        final summary = ValueNotifier('8 个频道');
        addTearDown(catalog.dispose);
        addTearDown(upload.dispose);
        addTearDown(summary.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: Container(
                    key: const ValueKey('channel-panel'),
                    width: width,
                    padding: const EdgeInsets.all(20),
                    child: ValueListenableBuilder<String>(
                      valueListenable: summary,
                      builder: (_, text, _) => SimpleChannelPanelHeader(
                        syncBadge: SharedSyncBadge(
                          catalog: catalog,
                          upload: upload,
                        ),
                        summary: text,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        void verifyAlignment() {
          final panel = tester.getRect(
            find.byKey(const ValueKey('channel-panel')),
          );
          final text = tester.getRect(
            find.byKey(const ValueKey('simple-channel-panel-summary')),
          );
          final badge = tester.getRect(find.byType(SharedSyncBadge));
          final title = tester.getRect(find.text('选台'));
          expect(text.right, closeTo(panel.right - 20, 0.1));
          expect(badge.right, closeTo(text.left - 8, 0.1));
          expect(badge.left, greaterThanOrEqualTo(panel.left + 20));
          expect(title.overlaps(badge), isFalse);
          expect(tester.takeException(), isNull);
        }

        verifyAlignment();
        summary.value = '1234 个频道 · 正在核对线路 9876/12345';
        catalog.value = const WebsiteCatalogProgress(
          phase: '正在同步网站频道',
          imported: 10,
          total: 100,
        );
        await tester.pump();
        verifyAlignment();
        expect(find.text('同步中'), findsOneWidget);

        upload.value = const WebsiteCatalogProgress(error: true);
        await tester.pump();
        verifyAlignment();
        expect(find.text('同步待重试'), findsOneWidget);

        // Resizing from the short summary to long progress must not move either
        // summary off the right edge or overlap the fixed title.
        summary.value = '0 个频道';
        catalog.value = const WebsiteCatalogProgress(complete: true);
        upload.value = const WebsiteCatalogProgress(complete: true);
        await tester.pump();
        verifyAlignment();
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
