import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('first favorite creates a default list and appears in all favorites', () async {
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
    final secondLists = await database.addChannelToDefaultFavorites('channel');

    expect(firstLists, hasLength(1));
    expect(secondLists, hasLength(1));
    expect(secondLists.single.name, '我的收藏');
    expect(await database.getAllFavoritedChannelIds(), {'channel'});
    expect(await database.getChannelsInList('default'), hasLength(1));

    await database.removeChannelFromList('default', 'channel');
    expect(await database.getAllFavoritedChannelIds(), isEmpty);
  });
}
