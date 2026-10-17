import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/models/server_epg_snapshot.dart';
import 'package:clubtivi/data/services/server_epg_sync_service.dart';
import 'package:clubtivi/features/settings/server_epg_attribution_tile.dart';

ServerEpgAttribution credit(String label) => ServerEpgAttribution.parse({
  'sourceId': 'fixture',
  'sourceLabel': label,
  'attributionUrl': 'https://www.tvmaze.com/',
  'licenseUrl': 'https://creativecommons.org/licenses/by-sa/4.0/',
  'modificationNotice': 'Normalized UTC timestamps.',
  'shareAlikeRequired': true,
});

void main() {
  testWidgets(
    'government data shows its real license without a sharealike claim',
    (tester) async {
      final state = ValueNotifier(
        ServerEpgSyncStatus(
          phase: 'updated',
          attributions: [
            ServerEpgAttribution.parse({
              'sourceId': 'fixture-government',
              'sourceLabel': 'Synthetic government provider 2026',
              'attributionUrl': 'https://data.gov.tw/dataset/121175',
              'licenseUrl': 'https://data.gov.tw/license',
              'modificationNotice': 'Synthetic UTC normalization fixture.',
              'shareAlikeRequired': false,
            }),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ServerEpgAttributionTile(state: state)),
        ),
      );
      await tester.tap(find.text('服务器节目表署名与许可'));
      await tester.pumpAndSettle();
      expect(
        find.text('节目数据许可：Open Government Data License 1.0'),
        findsOneWidget,
      );
      expect(find.text('https://data.gov.tw/license'), findsOneWidget);
      expect(find.text('改编数据须按相同许可共享。'), findsNothing);
      expect(find.text('使用数据及衍生资料须保留来源署名与许可声明。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'offline credits and license dialog hot update without replacing child',
    (tester) async {
      final state = ValueNotifier(
        ServerEpgSyncStatus(
          phase: 'failed',
          version: 'fixture-one',
          attributions: [credit('TVmaze')],
        ),
      );
      final scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ServerEpgAttributionTile(state: state),
                Expanded(
                  child: ListView(
                    controller: scroll,
                    children: [
                      for (var i = 0; i < 40; i++)
                        SizedBox(height: 50, child: Text('item $i')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      scroll.jumpTo(300);
      await tester.tap(find.text('服务器节目表署名与许可'));
      await tester.pumpAndSettle();
      expect(find.text('节目数据许可：CC BY-SA 4.0'), findsOneWidget);
      expect(
        find.text('https://creativecommons.org/licenses/by-sa/4.0/'),
        findsOneWidget,
      );
      expect(find.text('来源：https://www.tvmaze.com/'), findsOneWidget);
      expect(scroll.offset, 300);
      state.value = ServerEpgSyncStatus(
        phase: 'updated',
        version: 'fixture-two',
        attributions: [credit('Updated provider')],
      );
      await tester.pump();
      expect(find.text('Updated provider'), findsNWidgets(2));
      expect(find.text('TVmaze'), findsNothing);
      expect(scroll.offset, 300);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(scroll.offset, 300);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
      scroll.dispose();
    },
  );

  testWidgets('unpublished guide does not offer an empty credit dialog', (
    tester,
  ) async {
    final state = ValueNotifier(
      const ServerEpgSyncStatus(phase: 'unpublished'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ServerEpgAttributionTile(state: state)),
      ),
    );
    expect(find.text('尚无需要署名的服务器节目表'), findsOneWidget);
    await tester.tap(find.text('服务器节目表署名与许可'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
