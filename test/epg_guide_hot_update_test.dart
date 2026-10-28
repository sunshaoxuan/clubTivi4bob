import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:clubtivi/features/guide/guide_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final public in [false, true]) {
    testWidgets(
      'running guide replaces programmes without resetting its time scroll public=$public',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final database = db.AppDatabase.forTesting(NativeDatabase.memory());
        await database.upsertProvider(
          db.ProvidersCompanion.insert(
            id: public ? 'bobtv-channel-catalog' : 'p',
            name: 'P',
            type: 'm3u',
          ),
        );
        await database.upsertChannels([
          db.ChannelsCompanion.insert(
            id: 'c',
            providerId: public ? 'bobtv-channel-catalog' : 'p',
            name: 'Synthetic channel',
            streamUrl: 'https://example.org/live.m3u8',
          ),
        ]);
        await database.upsertEpgSource(
          db.EpgSourcesCompanion.insert(
            id: 's',
            name: 'S',
            url: 'https://example.org/guide.xml',
          ),
        );
        await database.upsertEpgChannels([
          db.EpgChannelsCompanion.insert(
            id: 's_exact',
            sourceId: 's',
            channelId: 'exact',
            displayName: 'Synthetic channel',
          ),
        ]);
        await database.upsertMapping(
          db.EpgMappingsCompanion.insert(
            channelId: 'c',
            providerId: public ? 'bobtv-channel-catalog' : 'p',
            epgChannelId: 'exact',
            epgSourceId: 's',
            source: Value(public ? 'local_xmltv' : 'manual'),
            locked: Value(!public),
          ),
        );
        final now = DateTime.now();
        final start = DateTime(now.year, now.month, now.day, now.hour);
        await database.insertEpgProgrammes([
          db.EpgProgrammesCompanion.insert(
            epgChannelId: 's_exact',
            sourceId: 's',
            title: 'Old synthetic programme',
            start: start,
            stop: start.add(const Duration(minutes: 50)),
          ),
        ]);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [databaseProvider.overrideWithValue(database)],
            child: const MaterialApp(home: GuideScreen()),
          ),
        );
        Future<void> settleDatabase() async {
          for (var i = 0; i < 8; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 30));
          }
        }

        await settleDatabase();
        expect(find.text('Old synthetic programme'), findsOneWidget);
        final state = tester.state(find.byType(GuideScreen));
        final ruler = tester
            .widgetList<SingleChildScrollView>(
              find.byType(SingleChildScrollView),
            )
            .firstWhere((w) => w.controller != null)
            .controller!;
        final before = ruler.offset;
        await database.transaction(() async {
          await (database.update(database.epgProgrammes)).write(
            const db.EpgProgrammesCompanion(
              title: Value('New synthetic programme'),
            ),
          );
        });
        await tester.pump(const Duration(milliseconds: 150));
        await settleDatabase();
        expect(find.text('New synthetic programme'), findsOneWidget);
        expect(find.text('Old synthetic programme'), findsNothing);
        expect(
          identical(tester.state(find.byType(GuideScreen)), state),
          isTrue,
        );
        expect(ruler.offset, before);
        await database
            .update(database.epgSources)
            .write(const db.EpgSourcesCompanion(enabled: Value(false)));
        await tester.pump(const Duration(milliseconds: 150));
        await settleDatabase();
        expect(find.text('New synthetic programme'), findsNothing);
        expect(ruler.offset, before);
        await tester.pumpWidget(const SizedBox());
        await database.close();
      },
    );
  }
}
