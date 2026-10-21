import 'package:clubtivi/data/services/channel_presentation_identity.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ChannelPresentationRoute route(
  String id, {
  String name = 'CCTV-6',
  String? catalogId,
  String? url,
  String? group,
  String? mergeId,
}) => ChannelPresentationRoute(
  id: id,
  name: name,
  url: url ?? 'https://media.example.org/$id.m3u8',
  group: group,
  catalogId: catalogId,
  mergeId: mergeId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unidentified names cannot collapse into one channel', () {
    expect(
      ChannelPresentationIdentity.keys([
        route('one', name: '---'),
        route('two', name: '___'),
      ]).values.toSet(),
      hasLength(2),
    );
  });

  test(
    'same route bridges public and old providers including old alternatives',
    () {
      final keys = ChannelPresentationIdentity.keys([
        route('public', catalogId: 'six', url: 'https://media.example.org/a'),
        route('old', name: 'CCTV6 电影', url: 'https://MEDIA.example.org:443/a'),
        route('alternative', name: 'CCTV-6 高清'),
      ]);
      expect(keys.values.toSet(), {'catalog:six'});
    },
  );

  test('same names alone cannot join public identities or a private route', () {
    final keys = ChannelPresentationIdentity.keys([
      route('one', catalogId: 'one'),
      route('two', catalogId: 'two'),
      route('private'),
    ]);
    expect(keys.values.toSet(), hasLength(3));
  });

  test('conflicting exact bridges leave the legacy group separate', () {
    final keys = ChannelPresentationIdentity.keys([
      route('p1', catalogId: 'one', url: 'https://media.example.org/a'),
      route('p2', catalogId: 'two', url: 'https://media.example.org/b'),
      route('l1', url: 'https://media.example.org/a'),
      route('l2', url: 'https://media.example.org/b'),
    ]);
    expect(keys['l1'], startsWith('legacy:'));
    expect(keys['l2'], keys['l1']);
    expect(keys['p1'], isNot(keys['p2']));
  });

  for (final other in [
    route('plus', name: 'CCTV-5+'),
    route('uhd', name: 'CCTV-5 4K'),
    route('audio', name: 'CCTV-5', group: '中国 / 广播'),
    route('wrong-name', name: 'CCTV-6'),
  ]) {
    test(
      'same URL cannot override service or media distinction ${other.id}',
      () {
        final keys = ChannelPresentationIdentity.keys([
          route('public', name: 'CCTV-5', catalogId: 'five', url: other.url),
          other,
        ]);
        expect(keys['public'], isNot(keys[other.id]));
      },
    );
  }

  test('same name and URL with different known countries remains separate', () {
    final keys = ChannelPresentationIdentity.keys([
      route(
        'p',
        name: 'Channel 8',
        catalogId: 'sg',
        group: '国际 / 新加坡',
        url: 'https://media.example.org/same',
      ),
      route(
        'l',
        name: 'Channel 8',
        group: '国际 / 泰国',
        url: 'https://media.example.org/same',
      ),
    ]);
    expect(keys['p'], isNot(keys['l']));
  });

  test('manual merge has priority without changing public identities', () {
    final keys = ChannelPresentationIdentity.keys([
      route('p', catalogId: 'six', mergeId: 'chosen'),
      route('l', mergeId: 'chosen'),
      route('other', catalogId: 'another'),
    ]);
    expect(keys['p'], keys['l']);
    expect(keys['p'], 'manual:chosen');
    expect(keys['other'], 'catalog:another');
  });

  test(
    'cards stay unique through refresh without switching the playing row',
    () {
      final routes = [route('old'), route('new')];
      for (final order in [routes, routes.reversed.toList()]) {
        final cards = ChannelPresentationIdentity.representatives(
          order,
          idOf: (r) => r.id,
          keyOf: (_) => 'catalog:six',
          scoreOf: (r) => r.id == 'new' ? 100 : 0,
          playingId: 'old',
        );
        expect(cards.single.id, 'old');
      }
      expect(routes, hasLength(2));
    },
  );

  test(
    'favorites bridge and unstar atomically without deleting channel rows',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      for (final provider in ['legacy', 'bobtv-channel-catalog']) {
        await database.upsertProvider(
          db.ProvidersCompanion.insert(
            id: provider,
            name: provider,
            type: 'm3u',
          ),
        );
      }
      await database.upsertChannels([
        for (final id in ['old', 'alternative', 'public'])
          db.ChannelsCompanion.insert(
            id: id,
            providerId: id == 'public' ? 'bobtv-channel-catalog' : 'legacy',
            name: id == 'old' ? 'CCTV6 电影' : 'CCTV-6',
            streamUrl:
                'https://media.example.org/${id == 'public' ? 'old' : id}',
            groupTitle: const Value('中国 / 央视'),
          ),
      ]);
      await database.customStatement(
        'INSERT INTO catalog_epg_routes VALUES(?,?,?,?,?,?)',
        ['public', 'six', 'hash', 'CCTV-6', null, '中国 / 央视'],
      );
      await database.addChannelToDefaultFavorites('old');
      expect(await database.getAllFavoritedChannelIds(), {
        'old',
        'alternative',
        'public',
      });
      final keys = await database.channelPresentationKeys(
        await database.getChannelsInList('default'),
      );
      expect(keys.values.toSet(), hasLength(1));
      // Public row absent from a category/favorite query still bridges by URL.
      expect(
        (await database.channelPresentationKeys(
          await database.getChannelsByIds({'old'}),
        ))['old'],
        keys['public'],
      );
      await database.removeChannelFromList('default', 'public');
      expect(await database.getAllFavoritedChannelIds(), isEmpty);
      expect(await database.getAllChannels(), hasLength(3));
      expect(await database.getAllMappings(), isEmpty);
    },
  );
}
