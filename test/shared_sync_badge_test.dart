import 'package:clubtivi/data/services/website_channel_catalog_service.dart';
import 'package:clubtivi/features/channels/shared_sync_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('sync progress, offline retry and completion remain visible', (
    tester,
  ) async {
    final catalog = ValueNotifier(
      const WebsiteCatalogProgress(phase: '正在下载网站频道', imported: 20, total: 100),
    );
    final upload = ValueNotifier(const WebsiteCatalogProgress(complete: true));
    addTearDown(catalog.dispose);
    addTearDown(upload.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SharedSyncBadge(catalog: catalog, upload: upload),
        ),
      ),
    );
    expect(find.text('同步中'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    catalog.value = const WebsiteCatalogProgress(complete: true);
    upload.value = const WebsiteCatalogProgress(
      phase: '同步待重试，本机修改已保存',
      error: true,
    );
    await tester.pump();
    expect(find.text('同步待重试'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    upload.value = const WebsiteCatalogProgress(
      phase: '频道变更已同步',
      complete: true,
    );
    await tester.pump();
    expect(find.text('已同步'), findsOneWidget);
  });
}
