import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'favorites include every service route and newly imported routes',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.upsertProvider(
        db.ProvidersCompanion.insert(id: 'provider', name: 'Test', type: 'm3u'),
      );
      db.ChannelsCompanion channel(String id, String name) =>
          db.ChannelsCompanion.insert(
            id: id,
            providerId: 'provider',
            name: name,
            streamUrl: 'https://example.com/$id.m3u8',
          );
      await database.upsertChannels([
        channel('a', 'CCTV-6'),
        channel('b', 'CCTV6 电影'),
        channel('plus', 'CCTV-5+'),
        channel('five', 'CCTV-5'),
        channel('fourK', 'CCTV-6 4K'),
      ]);
      await database.addChannelToDefaultFavorites('a');
      expect(await database.getAllFavoritedChannelIds(), {'a', 'b'});
      await database.upsertChannels([channel('new', 'CCTV-6 高清')]);
      expect(await database.getAllFavoritedChannelIds(), {'a', 'b', 'new'});
      await database.blockAndDeleteStreamUrl(
        'https://example.com/a.m3u8',
        reason: 'user_reported_wrong_content',
      );
      expect(
        (await database.getChannelsInList('default')).map((c) => c.id).toSet(),
        {'b', 'new'},
      );
      await database.removeChannelFromList('default', 'b');
      expect(await database.getAllFavoritedChannelIds(), isEmpty);
    },
  );

  test(
    'old one-route favorites expand without sharing with another database',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.upsertProvider(
        db.ProvidersCompanion.insert(id: 'p', name: 'Test', type: 'm3u'),
      );
      await database.upsertChannels([
        for (final id in ['a', 'b'])
          db.ChannelsCompanion.insert(
            id: id,
            providerId: 'p',
            name: 'CCTV-6',
            streamUrl: 'https://example.com/$id.m3u8',
          ),
      ]);
      await database.createFavoriteList('旧收藏');
      final list = (await database.getAllFavoriteLists()).single;
      await database
          .into(database.favoriteListChannels)
          .insert(
            db.FavoriteListChannelsCompanion.insert(
              listId: list.id,
              channelId: 'a',
            ),
          );
      expect(
        (await database.getChannelsInList(list.id)).map((c) => c.id).toSet(),
        {'a', 'b'},
      );
    },
  );

  test(
    'first favorite creates a default list and appears in all favorites',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.upsertProvider(
        db.ProvidersCompanion.insert(id: 'provider', name: 'Test', type: 'm3u'),
      );
      await database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'channel',
          providerId: 'provider',
          name: 'Test TV',
          streamUrl: 'https://example.com/live.m3u8',
        ),
      ]);

      final firstLists = await database.addChannelToDefaultFavorites('channel');
      final secondLists = await database.addChannelToDefaultFavorites(
        'channel',
      );

      expect(firstLists, hasLength(1));
      expect(secondLists, hasLength(1));
      expect(secondLists.single.name, '我的收藏');
      expect(await database.getAllFavoritedChannelIds(), {'channel'});
      expect(await database.getChannelsInList('default'), hasLength(1));

      await database.removeChannelFromList('default', 'channel');
      expect(await database.getAllFavoritedChannelIds(), isEmpty);
    },
  );
}
