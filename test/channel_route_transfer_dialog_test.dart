import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_route_transfer.dart';
import 'package:clubtivi/features/channels/channel_route_transfer_dialog.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'channel_merge_test.dart' show seedMerge, a, b;

void main() {
  for (final size in [
    const Size(1100, 850),
    const Size(600, 700),
    const Size(450, 650),
  ]) {
    testWidgets('transfer picker selects by identity and saves once at $size', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await tester.runAsync(() => seedMerge(database));
      final channel = await tester.runAsync(
        () async => (await database.getChannelsByIds({'one'})).single,
      );
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      ChannelRouteTransfer? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  saved = await showDialog<ChannelRouteTransfer>(
                    context: context,
                    builder: (_) => ChannelRouteTransferDialog(
                      database: database,
                      channel: channel!,
                      routeUrl: a,
                    ),
                  );
                },
                child: const Text('打开转移'),
              ),
            ),
          ),
        ),
      );
      Future<void> ready() async {
        for (var i = 0; i < 6; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.tap(find.text('打开转移'));
      await ready();
      expect(find.text('全部分类'), findsOneWidget);
      expect(find.text('当前频道'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField), 'Third');
      await tester.pump(const Duration(milliseconds: 200));
      await ready();
      await tester.tap(find.text('Third').last);
      await tester.pump();
      expect(find.text('转入：Third'), findsOneWidget);
      await tester.tap(find.text('转移线路'));
      await tester.pump();
      await ready();
      expect(saved?.name, 'Third');
      final events = await tester.runAsync(database.pendingSharedEvents);
      expect(events!.where((e) => e['kind'] == 'transfer'), hasLength(1));
      final untouched = await tester.runAsync(
        () => database.getChannelsByStreamUrls([b]),
      );
      expect(untouched!.single.name, 'News Alias');
      expect(tester.takeException(), isNull);
    });
  }
}
