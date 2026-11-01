import 'dart:async';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late db.AppDatabase database;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await database.upsertProvider(
      db.ProvidersCompanion.insert(id: 'fixture', name: 'Fixture', type: 'm3u'),
    );
  });
  tearDown(() => database.close());

  test(
    'channel invalidation has no initial full-table query and observes writes',
    () async {
      var calls = 0;
      final subscription = database.watchChannelChanges().listen(
        (_) => calls++,
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, 0);
      await database.transaction(() async {
        await database.upsertChannels([
          db.ChannelsCompanion.insert(
            id: 'a',
            providerId: 'fixture',
            name: 'CCTV-6',
            streamUrl: 'https://example.invalid/a',
          ),
        ]);
      });
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      await subscription.cancel();
    },
  );

  test(
    'stored favorites paint without expansion and reconciliation cannot undo a removal',
    () async {
      await database.upsertChannels([
        for (var i = 0; i < 450; i++)
          db.ChannelsCompanion.insert(
            id: 'c$i',
            providerId: 'fixture',
            name: 'CCTV-6',
            streamUrl: 'https://example.invalid/$i',
          ),
      ]);
      await database
          .into(database.favoriteLists)
          .insert(
            db.FavoriteListsCompanion.insert(id: 'default', name: 'Fixture'),
          );
      await database
          .into(database.favoriteListChannels)
          .insert(
            db.FavoriteListChannelsCompanion.insert(
              listId: 'default',
              channelId: 'c0',
            ),
          );
      expect(await database.getAllFavoritedChannelIds(reconcile: false), {
        'c0',
      });
      expect(
        await database.getChannelsInList('default', reconcile: false),
        hasLength(1),
      );
      final expansion = database.reconcileFavoriteMemberships();
      await database.removeChannelFromAllFavorites('c0');
      await expansion;
      expect(await database.getAllFavoritedChannelIds(), isEmpty);
      expect(await database.getAllChannels(), hasLength(450));
    },
  );
}
