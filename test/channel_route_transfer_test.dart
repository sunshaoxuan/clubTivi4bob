import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_merge.dart';
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/channel_inventory_sync_service.dart';
import 'package:clubtivi/data/services/manual_channel_category.dart';
import 'dart:io';
import 'package:clubtivi/data/services/stream_alternatives_service.dart';
import 'package:clubtivi/data/services/stream_health_tracker.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'channel_merge_test.dart' show seedMerge, a, b, c;

class TransferApi extends BobTvApiClient {
  bool offline = true;
  final received = <Map<String, Object?>>[];
  @override
  Future<List<Map<String, dynamic>>> uploadChannelEvents({
    required String fingerprint,
    required List<Map<String, Object?>> events,
  }) async {
    if (offline) throw const SocketException('offline');
    received.addAll(events);
    return [
      for (final event in events)
        {
          'id': event['id'],
          'status': 'applied',
          'revision': (event['baseRevision'] as int) + 1,
        },
    ];
  }
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
  Future<ChannelMergeChoice> third() async =>
      (await database.searchChannelMergeChoices(query: 'Third')).single;

  test(
    'single canonical route and duplicates move, other routes stay unchanged',
    () async {
      final tracker = StreamHealthTracker()..recordPlaybackSuccess(a);
      final score = tracker.getScore(a);
      final result = await database.transferRoute(a, await third());
      expect(result.name, 'Third');
      expect(
        (await database.getChannelsByStreamUrls([
          a,
        ])).map((c) => c.name).toSet(),
        {'Third'},
      );
      expect(
        (await database.getChannelsByStreamUrls([b])).single.name,
        'News Alias',
      );
      expect(
        (await database.getChannelsByStreamUrls([c])).single.name,
        'Third',
      );
      expect(tracker.getScore(a), score);
      expect(await database.isStreamUrlBlocked(a), isFalse);
      final events = await database.pendingSharedEvents();
      expect(events, hasLength(1));
      expect(events.single['kind'], 'transfer');
      expect(events.single['payload'], {
        'url': a,
        'targetUrl': c,
        'baseRevision': 0,
        'targetRevision': 0,
      });
      expect(await database.pendingSharedTransferUrls(), {a});
      final alternatives = StreamAlternativesService(database, tracker);
      await alternatives.rebuild();
      expect(
        alternatives.getAlternatives(
          channelId: 'third',
          channelName: 'Third',
          excludeUrl: c,
        ),
        contains(a),
      );
      expect(
        alternatives.getAlternatives(
          channelId: 'third', channelName: 'Third', excludeUrl: c,
        ),
        isNot(contains(b)),
      );
      final identities = await database.publicCatalogChannelIds({'one', 'third'});
      expect(identities['one'], identities['third']);
    },
  );

  test(
    'refresh cannot move a transferred route back, category edits still apply',
    () async {
      await database.transferRoute(a, await third());
      await database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'one',
          providerId: 'bobtv-channel-catalog',
          name: 'Old',
          streamUrl: a,
          tvgId: const Value('WRONG'),
          groupTitle: const Value('中国 / 北京'),
        ),
      ]);
      final moved = (await database.getChannelsByIds({'one'})).single;
      expect(moved.name, 'Third');
      expect(moved.groupTitle, '国际 / 英国 / 新闻');
      expect(moved.tvgId, isNull);
      expect((await database.pendingSharedEvents()).map((e) => e['kind']), [
        'transfer',
      ]);
    },
  );

  test(
    'splitting one member does not transfer the rest of a previous merge',
    () async {
      final id = await database.mergeChannels(
        ChannelMergePlan(name: 'Unified', group: '其他', urls: [a, b]),
      );
      await database.transferRoute(a, await third());
      expect(
        (await database.getChannelsByStreamUrls([b])).single.name,
        'Unified',
      );
      expect(await database.channelMergeIds([a, b]), {b: id});
      await database.advanceQueuedTransferRevision(a, 0, 1);
      final transfer = (await database.pendingSharedEvents()).firstWhere(
        (e) => e['kind'] == 'transfer',
      );
      expect((transfer['payload'] as Map)['baseRevision'], 1);
    },
  );

  test('retired, missing or same destination makes no transfer', () async {
    final choice = await third();
    await expectLater(database.transferRoute(c, choice), throwsArgumentError);
    await expectLater(
      database.transferRoute('https://media.example.org/missing', choice),
      throwsStateError,
    );
    await database.blockAndDeleteStreamUrl(a, reason: 'test');
    await expectLater(database.transferRoute(a, choice), throwsStateError);
    expect(await database.pendingSharedTransferUrls(), isEmpty);
  });

  test('public route cannot be assigned to a private destination', () async {
    await database.upsertProvider(
      db.ProvidersCompanion.insert(
        id: 'private',
        name: 'Personal',
        type: 'xtream',
        username: const Value('account'),
      ),
    );
    await database.upsertChannels([
      db.ChannelsCompanion.insert(
        id: 'private-one',
        providerId: 'private',
        name: 'Private TV',
        streamUrl: 'https://private.example.org/live/account/pass/1.ts',
      ),
    ]);
    final choice = (await database.searchChannelMergeChoices(
      query: 'Private TV',
    )).single;
    await expectLater(database.transferRoute(a, choice), throwsStateError);
    expect(await database.pendingSharedTransferUrls(), isEmpty);
  });

  test('private account route transfers locally without publishing credentials', () async {
    await database.upsertProvider(db.ProvidersCompanion.insert(id: 'private', name: 'Personal',
      type: 'xtream', username: const Value('account')));
    const privateUrl = 'https://private.example.org/live/account/pass/1.ts';
    await database.upsertChannels([
      db.ChannelsCompanion.insert(id: 'private-one', providerId: 'private', name: 'Private One', streamUrl: privateUrl),
      db.ChannelsCompanion.insert(id: 'private-two', providerId: 'private', name: 'Private Two',
        streamUrl: 'https://private.example.org/live/account/pass/2.ts'),
    ]);
    final target = (await database.searchChannelMergeChoices(query: 'Private Two')).single;
    final result = await database.transferRoute(privateUrl, target);
    expect(result.shared, isFalse);
    expect((await database.getChannelsByStreamUrls([privateUrl])).single.name, 'Private Two');
    expect(await database.pendingSharedEvents(), isEmpty);
  });

  test(
    'offline transfer followed by classification keeps operation order and revisions',
    () async {
      await database.transferRoute(a, await third());
      await database.setManualChannelCategory([
        a,
      ], ChannelCategoryDestination(['英国', '娱乐']));
      expect((await database.pendingSharedEvents()).map((e) => e['kind']), [
        'transfer',
        'classify',
      ]);
      final api = TransferApi();
      final sync = ChannelInventorySyncService(
        database: database,
        api: api,
        fingerprintOverride: 'a' * 64,
      );
      addTearDown(sync.dispose);
      expect(await sync.flushEvents(), 0);
      expect(await database.pendingSharedEvents(), hasLength(2));
      api.offline = false;
      expect(await sync.flushEvents(), 2);
      expect(api.received.map((e) => e['kind']), ['transfer', 'classify']);
      expect(api.received.last['baseRevision'], 1);
      expect(await database.sharedRouteRevision(a), 2);
      expect(await database.pendingSharedEvents(), isEmpty);
    },
  );
}
