import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

db.ChannelsCompanion route(String id) => db.ChannelsCompanion.insert(
  id: id,
  providerId: 'p',
  name: id == 'other' ? 'CCTV-5+' : 'CCTV-6',
  streamUrl: 'https://example.com/$id.m3u8',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await database.upsertProvider(
      db.ProvidersCompanion.insert(id: 'p', name: 'Test', type: 'm3u'),
    );
    await database.upsertChannels([route('a'), route('b'), route('other')]);
    await database.addChannelToDefaultFavorites('a');
    await database.addChannelToDefaultFavorites('other');
  });
  tearDown(() => database.close());

  test(
    'remove all and undo preserve other services and existing lists',
    () async {
      final sports = await database.createFavoriteList('体育');
      await database.addChannelToList(sports.id, 'b');
      final removed = await database.removeChannelFromAllFavorites('a');
      expect(removed.toSet(), {'default', sports.id});
      expect(await database.getAllFavoritedChannelIds(), {'other'});
      expect(await database.getAllChannels(), hasLength(3));
      await database.restoreChannelFavoriteLists('b', removed);
      expect(await database.getAllFavoritedChannelIds(), {'a', 'b', 'other'});
      expect(
        (await database.getChannelsInList(sports.id)).map((c) => c.id).toSet(),
        {'a', 'b'},
      );
      await database.removeChannelFromList('default', 'a');
      expect((await database.getListsForChannel('a')).map((l) => l.id), [
        sports.id,
      ]);
      await database.removeChannelFromAllFavorites('b');
      await database.deleteFavoriteList(sports.id);
      await database.restoreChannelFavoriteLists('a', removed);
      expect((await database.getAllFavoriteLists()).map((l) => l.id), [
        'default',
      ]);
    },
  );

  test('removal clears blocked legacy members of the same service', () async {
    await database
        .into(database.blockedStreamRoutes)
        .insert(
          db.BlockedStreamRoutesCompanion.insert(
            streamUrl: 'https://example.com/b.m3u8',
            reason: 'private:fixture',
          ),
        );
    await database.removeChannelFromList('default', 'a');
    await database.reconcileFavoriteMemberships(force: true);
    expect(await database.getAllFavoritedChannelIds(), {'other'});
  });

  test(
    'new synchronized routes cannot resurrect a concurrent removal',
    () async {
      await Future.wait([
        database.upsertChannels([route('new')]),
        database.removeChannelFromAllFavorites('a'),
      ]);
      await database.reconcileFavoriteMemberships(force: true);
      expect(await database.getAllFavoritedChannelIds(), {'other'});
      await database.upsertChannels([route('later')]);
      expect(await database.getAllFavoritedChannelIds(), {'other'});
    },
  );
}
