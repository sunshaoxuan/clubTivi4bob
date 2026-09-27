import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/website_channel_catalog_service.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CatalogApi extends BobTvApiClient {
  _CatalogApi(this.catalog);

  Map<String, Object?>? catalog;
  String version = '2026-09-28.1';

  List<int> get bytes => gzip.encode(utf8.encode(jsonEncode(catalog)));

  @override
  Future<BobTvChannelCatalogManifest?> fetchChannelCatalogManifest() async {
    if (catalog == null) return null;
    final digest = sha256.convert(bytes).toString();
    return BobTvChannelCatalogManifest(
      version: version,
      channelCount: (catalog!['channels'] as List).length,
      routeCount: 1,
      snapshotPath: '/api/v1/channel-catalog/snapshots/$digest.json.gz',
      compressedBytes: bytes.length,
      sha256: digest,
    );
  }

  @override
  Future<List<int>> downloadChannelCatalog(
      BobTvChannelCatalogManifest manifest) async => bytes;
}

Map<String, Object?> _catalog() => {
  'schemaVersion': 1,
  'version': '2026-09-28.1',
  'categories': [
    {'id': 'cn', 'parentId': null, 'name': '中国'},
    {'id': 'cn-cctv', 'parentId': 'cn', 'name': '央视'},
  ],
  'channels': [{
    'id': 'cctv-5-plus', 'name': 'CCTV-5+ 体育赛事',
    'categoryId': 'cn-cctv', 'sortOrder': 25,
    'epgId': 'cctv5plus', 'logoUrl': null,
    'routes': [{
      'id': 'route-one',
      'url': 'https://media.example.org/live.m3u8',
    }],
  }],
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('imports a classified website route and preserves its favorite', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final api = _CatalogApi(_catalog());
    final service = WebsiteChannelCatalogService(database: database, api: api);
    addTearDown(() async {
      service.dispose();
      await database.close();
    });
    expect(await service.sync(), 1, reason: '${service.lastError}');
    var channels = await database.getChannelsForProvider(
      WebsiteChannelCatalogService.providerId);
    expect(channels.single.name, 'CCTV-5+ 体育赛事');
    expect(channels.single.groupTitle, '中国 / 央视');
    await database.upsertChannels([
      db.ChannelsCompanion.insert(
        id: channels.single.id,
        providerId: WebsiteChannelCatalogService.providerId,
        name: channels.single.name,
        streamUrl: channels.single.streamUrl,
        groupTitle: const Value('中国 / 央视'),
        favorite: const Value(true),
      ),
    ]);
    api.version = '2026-09-28.2';
    api.catalog = {..._catalog(), 'version': api.version};
    expect(await service.sync(), 1);
    channels = await database.getChannelsForProvider(
      WebsiteChannelCatalogService.providerId);
    expect(channels.single.favorite, isTrue);
    api.catalog = null;
    expect(await service.sync(), 0);
    expect((await database.getChannelsForProvider(
      WebsiteChannelCatalogService.providerId)).length, 1);
  });

  test('rejects malformed snapshot before touching the local database', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final payload = _catalog();
    ((payload['channels'] as List).single['routes'] as List).single['url'] =
        'http://127.0.0.1/private';
    final service = WebsiteChannelCatalogService(
      database: database, api: _CatalogApi(payload));
    addTearDown(() async {
      service.dispose();
      await database.close();
    });
    expect(await service.sync(), 0);
    expect(service.state.value.error, isTrue);
    expect(await database.getAllProviders(), isEmpty);
  });
}
