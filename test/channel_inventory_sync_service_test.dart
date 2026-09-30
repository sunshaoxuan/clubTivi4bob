import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/channel_inventory_sync_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:drift/drift.dart' show Value;

class InventoryApi extends BobTvApiClient {
  final batches = <List<Map<String, Object?>>>[];
  @override
  Future<int> uploadChannelInventory({
    required String fingerprint,
    required List<Map<String, Object?>> routes,
  }) async {
    batches.add(routes);
    return routes.length;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('personal subscriptions and their retirements remain local', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final api = InventoryApi();
    final service = ChannelInventorySyncService(
      database: database,
      api: api,
      fingerprintOverride: 'b' * 64,
    );
    addTearDown(() async {
      service.dispose();
      await database.close();
    });
    for (final type in ['m3u', 'xtream']) {
      await database.upsertProvider(
        db.ProvidersCompanion.insert(
          id: type,
          name: 'Personal',
          type: type,
          url: const Value('https://personal.example.org/subscription.m3u'),
        ),
      );
      await database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: type,
          providerId: type,
          name: 'CCTV1',
          streamUrl: 'https://personal.example.org/$type.m3u8',
        ),
      ]);
    }
    await database.blockAndDeleteStreamUrl(
      'https://personal.example.org/m3u.m3u8',
      reason: 'manual',
    );
    await service.reportRetirement('https://personal.example.org/m3u.m3u8');
    await service.sync();
    expect(api.batches, isEmpty);
    expect(await database.getBlockedStreamUrls(), hasLength(1));
    expect(await database.getSharedBlockedStreamUrls(), isEmpty);
    expect(
      BobTvApiClient.isPublicCatalogUrl(
        'https://media.example.org/live/user/password/1.ts',
      ),
      isFalse,
    );
  });
  test('uploads every page, categories and removed-route tombstones', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final api = InventoryApi();
    final service = ChannelInventorySyncService(
      database: database,
      api: api,
      fingerprintOverride: 'a' * 64,
    );
    addTearDown(() async {
      service.dispose();
      await database.close();
    });
    await database.upsertProvider(
      db.ProvidersCompanion.insert(
        id: 'test',
        name: 'test',
        type: 'm3u',
        url: const Value(
          'https://raw.githubusercontent.com/public/tv/main/tv.m3u',
        ),
      ),
    );
    await database.upsertChannels(
      List.generate(
        451,
        (i) => db.ChannelsCompanion.insert(
          id: 'channel-${i.toString().padLeft(4, '0')}',
          providerId: 'test',
          name: 'CCTV1',
          streamUrl: 'https://media.example.org/$i.m3u8',
        ),
      ),
    );
    await database.blockAndDeleteStreamUrl(
      'https://media.example.org/0.m3u8',
      reason: 'test',
    );
    await service.sync();
    expect(service.state.value.error, isFalse);
    expect(api.batches.every((batch) => batch.length <= 200), isTrue);
    final rows = api.batches.expand((batch) => batch).toList();
    expect(rows.length, 451);
    expect(
      rows.where((row) => row['blocked'] == true).single['url'],
      'https://media.example.org/0.m3u8',
    );
    expect(
      rows.where((row) => row['blocked'] == false).first['group'],
      '中国 / 央视',
    );
    api.batches.clear();
    await service.sync();
    expect(api.batches.expand((batch) => batch).length, 1);
  });
}
