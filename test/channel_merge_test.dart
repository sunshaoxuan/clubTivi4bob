import 'dart:convert';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_merge.dart';
import 'package:clubtivi/data/services/stream_alternatives_service.dart';
import 'package:clubtivi/data/services/stream_health_tracker.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const a = 'https://media.example.org/a.m3u8';
const b = 'https://media.example.org/b.m3u8';
const c = 'https://media.example.org/c.m3u8';
Future<void> seedMerge(db.AppDatabase database) async {
  await database.withoutSharedReporting(() async {
    await database.upsertProvider(
      db.ProvidersCompanion.insert(
        id: 'bobtv-channel-catalog',
        name: 'Shared',
        type: 'catalog',
      ),
    );
    await database.upsertChannels([
      db.ChannelsCompanion.insert(
        id: 'one',
        providerId: 'bobtv-channel-catalog',
        name: 'News One',
        groupTitle: const Value('国际 / 美国 / 新闻'),
        streamUrl: a,
      ),
      db.ChannelsCompanion.insert(
        id: 'alias',
        providerId: 'bobtv-channel-catalog',
        name: 'News Alias',
        groupTitle: const Value('国际 / 美国 / 综合'),
        streamUrl: b,
      ),
      db.ChannelsCompanion.insert(
        id: 'duplicate',
        providerId: 'bobtv-channel-catalog',
        name: 'Another Name',
        groupTitle: const Value('国际 / 英国 / 新闻'),
        streamUrl: a,
      ),
      db.ChannelsCompanion.insert(
        id: 'third',
        providerId: 'bobtv-channel-catalog',
        name: 'Third',
        groupTitle: const Value('国际 / 英国 / 新闻'),
        streamUrl: c,
      ),
    ]);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await seedMerge(database);
  });
  tearDown(() => database.close());

  test(
    'cross-category merge deduplicates URLs and queues one atomic event',
    () async {
      final id = await database.mergeChannels(
        ChannelMergePlan(
          name: 'Unified',
          group: '国际 / 美国 / 新闻',
          urls: [a, b, a],
        ),
      );
      final owners = await database.getChannelsByStreamUrls([a, b]);
      expect(owners.map((c) => c.name).toSet(), {'Unified'});
      expect(owners.map((c) => c.groupTitle).toSet(), {'国际 / 美国 / 新闻'});
      expect((await database.channelMergeIds([a, b])).values.toSet(), {id});
      final events = await database.pendingSharedEvents();
      expect(events, hasLength(1));
      expect(events.single['kind'], 'merge');
      final payload = events.single['payload'] as Map;
      expect(payload['routes'], hasLength(2));
      expect(await database.pendingSharedMergeUrls(), {a, b});
    },
  );

  test(
    'upstream refresh preserves manual merge and no accidental delete event',
    () async {
      await database.mergeChannels(
        ChannelMergePlan(
          name: 'Unified',
          group: '国际 / 美国 / 新闻',
          urls: [a, b],
          epgId: 'NEWS',
        ),
      );
      await database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'one',
          providerId: 'bobtv-channel-catalog',
          name: 'Old',
          streamUrl: a,
          groupTitle: const Value('中国 / 北京'),
          tvgId: const Value('WRONG'),
        ),
      ]);
      final owner = (await database.getChannelsByIds({'one'})).single;
      expect(owner.name, 'Unified');
      expect(owner.tvgId, 'NEWS');
      expect(owner.groupTitle, '国际 / 美国 / 新闻');
      expect((await database.pendingSharedEvents()).map((e) => e['kind']), [
        'merge',
      ]);
    },
  );

  test(
    'merge again includes all prior members and preserves route health',
    () async {
      final tracker = StreamHealthTracker();
      tracker.recordPlaybackSuccess(a);
      final score = tracker.getScore(a);
      await database.mergeChannels(
        ChannelMergePlan(name: 'Unified', group: '国际 / 美国 / 新闻', urls: [a, b]),
      );
      final id = await database.mergeChannels(
        ChannelMergePlan(name: 'Bigger', group: '国际 / 美国 / 新闻', urls: [b, c]),
      );
      expect((await database.channelMergeIds([a, b, c])).values.toSet(), {id});
      expect(tracker.getScore(a), score);
      final service = StreamAlternativesService(database, tracker);
      await service.rebuild();
      expect(
        service
            .getAlternatives(
              channelId: 'one',
              channelName: 'Bigger',
              excludeUrl: a,
            )
            .toSet(),
        {b, c},
      );
    },
  );

  test(
    'search is paged, category-scoped and treats wildcard input literally',
    () async {
      expect(
        await database.searchChannelMergeChoices(
          query: 'News',
          group: '国际 / 美国 / 新闻',
        ),
        hasLength(1),
      );
      expect(
        await database.searchChannelMergeChoices(query: 'News'),
        hasLength(2),
      );
      expect(await database.searchChannelMergeChoices(query: '%'), isEmpty);
      expect(await database.searchChannelMergeChoices(limit: 1), hasLength(1));
    },
  );

  test('invalid plan makes no change', () async {
    expect(
      () => database.mergeChannels(
        ChannelMergePlan(name: ' ', group: '其他', urls: [a, b]),
      ),
      throwsArgumentError,
    );
    expect(await database.channelMergeIds([a, b]), isEmpty);
    expect(await database.pendingSharedEvents(), isEmpty);
  });

  test('personal account URLs never enter public merge payload', () async {
    await database.upsertProvider(
      db.ProvidersCompanion.insert(
        id: 'private',
        name: 'Personal',
        type: 'xtream',
        username: const Value('account'),
      ),
    );
    const privateUrl = 'https://private.example.org/live/account/pass/1.ts';
    await database.upsertChannels([
      db.ChannelsCompanion.insert(
        id: 'private-one',
        providerId: 'private',
        name: 'Alias',
        streamUrl: privateUrl,
      ),
    ]);
    await database.mergeChannels(
      ChannelMergePlan(name: 'Unified', group: '其他', urls: [a, privateUrl]),
    );
    final event = (await database.pendingSharedEvents()).single;
    expect(jsonEncode(event), isNot(contains('account')));
    expect((event['payload'] as Map)['routes'], hasLength(1));
    expect(
      (await database.getChannelsByIds({'private-one'})).single.name,
      'Unified',
    );
  });
}
