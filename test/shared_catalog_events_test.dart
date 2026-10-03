import 'dart:io';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_inventory_sync_service.dart';
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/manual_channel_category.dart';
import 'package:clubtivi/data/services/stream_health_tracker.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const url = 'https://media.example.org/news.m3u8';

class EventApi extends BobTvApiClient {
  bool offline = false;
  final events = <Map<String, Object?>>[];
  @override
  Future<List<Map<String, dynamic>>> uploadChannelEvents({
    required String fingerprint,
    required List<Map<String, Object?>> events,
  }) async {
    if (offline) throw const SocketException('offline');
    this.events.addAll(events);
    return [
      for (final e in events)
        {
          'id': e['id'],
          'status': 'applied',
          'revision': e['kind'] == 'classify'
              ? (e['baseRevision'] as int) + 1
              : e['baseRevision'] ?? 0,
        },
    ];
  }
}

Future<void> seed(db.AppDatabase database) async {
  await database.upsertProvider(
    db.ProvidersCompanion.insert(
      id: 'bobtv-channel-catalog',
      name: 'shared',
      type: 'catalog',
    ),
  );
  await database.upsertChannels([
    db.ChannelsCompanion.insert(
      id: 'news',
      providerId: 'bobtv-channel-catalog',
      name: 'News',
      streamUrl: url,
      groupTitle: const Value('国际 / 美国 / 新闻'),
    ),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('durable queue survives offline failure and database restart', () async {
    final dir = await Directory.systemTemp.createTemp('bobtv-sync-test-');
    final file = File('${dir.path}/test.sqlite');
    var database = db.AppDatabase.forTesting(NativeDatabase(file));
    await seed(database);
    final api = EventApi()..offline = true;
    final service = ChannelInventorySyncService(
      database: database,
      api: api,
      fingerprintOverride: 'a' * 64,
    );
    expect(await service.flushEvents(), 0);
    expect(await database.pendingSharedEvents(), hasLength(1));
    service.dispose();
    await database.close();
    database = db.AppDatabase.forTesting(NativeDatabase(file));
    final next = ChannelInventorySyncService(
      database: database,
      api: EventApi(),
      fingerprintOverride: 'a' * 64,
    );
    expect(await next.flushEvents(), 1);
    expect(await database.pendingSharedEvents(), isEmpty);
    next.dispose();
    await database.close();
    await dir.delete(recursive: true);
  });
  test(
    'import and favorite updates do not echo; insert edit delete do',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.withoutSharedReporting(() => seed(database));
      expect(await database.pendingSharedEvents(), isEmpty);
      await database.addChannelToDefaultFavorites('news');
      expect(await database.pendingSharedEvents(), isEmpty);
      await database.setManualChannelCategory([
        url,
      ], ChannelCategoryDestination(['美国', '宗教']));
      expect((await database.pendingSharedEvents()).single['kind'], 'classify');
      await database.queueSharedEvent(url, 'health', {
        'success': 2,
        'failure': 0,
      });
      await database.deleteChannelsByIds(['news']);
      expect(
        (await database.pendingSharedEvents()).map((e) => e['kind']),
        containsAll(['classify', 'health', 'delete']),
      );
    },
  );
  test(
    'acknowledging old coalesced event cannot delete a new update',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await seed(database);
      final old = (await database.pendingSharedEvents()).single['id'] as String;
      await database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'news',
          providerId: 'bobtv-channel-catalog',
          name: 'New name',
          streamUrl: url,
        ),
      ]);
      await database.acknowledgeSharedEvent(old);
      expect(await database.pendingSharedEvents(), hasLength(1));
      expect((await database.pendingSharedEvents()).single['id'], isNot(old));
    },
  );
  test('rollback leaves no queued mutation', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await expectLater(
      database.transaction(() async {
        await seed(database);
        throw StateError('rollback');
      }),
      throwsStateError,
    );
    expect(await database.pendingSharedEvents(), isEmpty);
  });
  test('private subscriptions never queue metadata or weight events', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.upsertProvider(
      db.ProvidersCompanion.insert(
        id: 'private',
        name: 'private',
        type: 'm3u',
        url: const Value('https://private.example.org/list'),
      ),
    );
    await database.upsertChannels([
      db.ChannelsCompanion.insert(
        id: 'private',
        providerId: 'private',
        name: 'News',
        streamUrl: url,
      ),
    ]);
    await database.queueSharedEvent(url, 'health', {'success': 1});
    await database.deleteChannelsByIds(['private']);
    expect(await database.pendingSharedEvents(), isEmpty);
  });
  test('new device uses shared weights and keeps local learning', () async {
    final tracker = StreamHealthTracker();
    await tracker.load();
    await tracker.setSharedScores({url: .2});
    expect(tracker.getScore(url), .2);
    tracker.recordPlaybackSuccess(url);
    expect(tracker.getScore(url), greaterThan(.2));
    await tracker.save();
  });
}
