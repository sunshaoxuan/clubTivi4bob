import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/channel_inventory_sync_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
      db.ProvidersCompanion.insert(id: 'test', name: 'test', type: 'm3u'),
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
