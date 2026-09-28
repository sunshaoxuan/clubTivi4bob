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
      routeCount: (catalog!['channels'] as List).fold<int>(0,
          (count, channel) => count + (channel['routes'] as List).length),
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

  test('two installations receive the same shared routes', () async {
    final first = db.AppDatabase.forTesting(NativeDatabase.memory());
    final second = db.AppDatabase.forTesting(NativeDatabase.memory());
    final api = _CatalogApi(_catalog());
    final firstSync = WebsiteChannelCatalogService(database: first, api: api);
    final secondSync = WebsiteChannelCatalogService(
        database: second, api: _CatalogApi(_catalog()));
    addTearDown(() async {
      firstSync.dispose();
      secondSync.dispose();
      await first.close();
      await second.close();
    });
    expect(await firstSync.sync(), 1);
    expect(await secondSync.sync(), 1);
    final firstRoutes = await first.getChannelsForProvider(
        WebsiteChannelCatalogService.providerId);
    final secondRoutes = await second.getChannelsForProvider(
        WebsiteChannelCatalogService.providerId);
    expect(firstRoutes.map((route) => (route.id, route.streamUrl)),
        secondRoutes.map((route) => (route.id, route.streamUrl)));
    expect(WebsiteChannelCatalogService.showInSimpleMode(
      sharedCatalogAvailable: true,
      personalCollection: false,
      providerId: WebsiteChannelCatalogService.providerId,
    ), isTrue);
    expect(WebsiteChannelCatalogService.showInSimpleMode(
      sharedCatalogAvailable: true,
      personalCollection: false,
      providerId: 'hotel-myiptv-ipv4',
    ), isFalse);
    expect(WebsiteChannelCatalogService.showInSimpleMode(
      sharedCatalogAvailable: true,
      personalCollection: true,
      providerId: 'hotel-myiptv-ipv4',
    ), isTrue);
  });

  test('withdrawn shared routes leave every device, even when favorited', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final catalog = _catalog();
    final routes = ((catalog['channels'] as List).single['routes'] as List);
    routes.add({'id': 'route-two', 'url': 'https://media.example.org/alt.m3u8'});
    final api = _CatalogApi(catalog);
    final service = WebsiteChannelCatalogService(database: database, api: api);
    addTearDown(() async {
      service.dispose();
      await database.close();
    });
    expect(await service.sync(), 2);
    final original = (await database.getChannelsForProvider(
        WebsiteChannelCatalogService.providerId)).firstWhere(
        (route) => route.id.endsWith('route-one'));
    await database.upsertChannels([db.ChannelsCompanion.insert(
      id: original.id,
      providerId: original.providerId,
      name: original.name,
      streamUrl: original.streamUrl,
      favorite: const Value(true),
    )]);
    routes.removeAt(0);
    api.version = '2026-09-28.2';
    catalog['version'] = api.version;
    expect(await service.sync(), 1);
    final remaining = await database.getChannelsForProvider(
        WebsiteChannelCatalogService.providerId);
    expect(remaining.map((route) => route.id),
        ['${WebsiteChannelCatalogService.providerId}:route-two']);
  });

  test('locally blocked route stays blocked after website refresh', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    const url = 'https://media.example.org/live.m3u8';
    await database.blockAndDeleteStreamUrl(url,
        reason: 'user_reported_wrong_content');
    final api = _CatalogApi(_catalog());
    final service = WebsiteChannelCatalogService(database: database, api: api);
    addTearDown(() async {
      service.dispose();
      await database.close();
    });
    expect(await service.sync(), 0);
    expect(await database.getChannelsForProvider(
        WebsiteChannelCatalogService.providerId), isEmpty);
    expect(await service.sync(), 0);
    expect(service.state.value.error, isFalse);
  });

  test('shared categories include routes without matching name keywords', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.upsertProvider(db.ProvidersCompanion.insert(
      id: WebsiteChannelCatalogService.providerId,
      name: 'BobTV 网站频道',
      type: 'catalog',
    ));
    await database.upsertChannels([
      db.ChannelsCompanion.insert(
        id: '${WebsiteChannelCatalogService.providerId}:regional-one',
        providerId: WebsiteChannelCatalogService.providerId,
        name: 'Morning Live',
        streamUrl: 'https://media.example.org/morning.m3u8',
        groupTitle: const Value('中国 / 广东'),
      ),
      db.ChannelsCompanion.insert(
        id: '${WebsiteChannelCatalogService.providerId}:international-one',
        providerId: WebsiteChannelCatalogService.providerId,
        name: 'World One',
        streamUrl: 'https://media.example.org/world.m3u8',
        groupTitle: const Value('国际 / 美国 / 新闻'),
      ),
    ]);
    expect((await database.getChannelCategoryCandidates('广东'))
        .map((channel) => channel.name), contains('Morning Live'));
    expect((await database.getChannelCategoryCandidates('国际'))
        .map((channel) => channel.name), contains('World One'));
  });
}
