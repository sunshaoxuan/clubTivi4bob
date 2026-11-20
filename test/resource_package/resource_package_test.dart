import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/resource_package/resource_package.dart';
import 'package:clubtivi/data/resource_package/resource_package_client.dart';
import 'package:clubtivi/data/resource_package/resource_package_store.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_presentation_identity.dart';
import 'package:clubtivi/core/server_egress.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:clubtivi/data/services/server_epg_sync_service.dart';
import 'package:clubtivi/data/services/epg_refresh_service.dart';
import 'package:clubtivi/data/services/website_channel_catalog_service.dart';
import 'package:clubtivi/data/services/bobtv_api_client.dart';

Map<String, dynamic> fixture() => {
  'format': 'bobtv-resource',
  'schemaVersion': 1,
  'id': 'demo',
  'name': 'Demo',
  'revision': '1',
  'categories': [
    {'id': 'news', 'name': '新闻'},
  ],
  'epgSources': [
    {'id': 'guide', 'url': 'https://guide.example/epg.xml'},
  ],
  'channels': [
    {
      'id': 'one',
      'name': 'Same name',
      'categoryId': 'news',
      'epg': {'sourceId': 'guide', 'channelId': 'guide.one'},
      'routes': [
        {'id': 'a', 'url': 'https://media.example/a.m3u8'},
        {'id': 'b', 'url': 'https://media.example/b.m3u8'},
      ],
    },
  ],
};
ResourcePackage parse(Map<String, dynamic> value) =>
    ResourcePackage.parse(jsonEncode(value));
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('minimal package resolves categories, routes and EPG references', () {
    final p = parse(fixture());
    expect(p.routeCount, 2);
    expect(p.channels.single.group, '新闻');
    expect(p.channels.single.epgChannelId, 'guide.one');
  });
  for (final mutation in <String, void Function(Map<String, dynamic>)>{
    'unknown version': (p) => p['schemaVersion'] = 2,
    'wrong field type': (p) => p['categories'] = {},
    'duplicate channel ID': (p) => p['channels'].add(p['channels'].first),
    'missing category': (p) => p['channels'][0]['categoryId'] = 'missing',
    'missing guide': (p) => p['channels'][0]['epg']['sourceId'] = 'missing',
    'executable extension': (p) => p['script'] = 'eval',
    'empty routes': (p) => p['channels'][0]['routes'] = [],
    'duplicate route ID': (p) => p['channels'][0]['routes'][1]['id'] = 'a',
    'invalid URL': (p) =>
        p['channels'][0]['routes'][0]['url'] = 'javascript:alert(1)',
    'URL credentials': (p) =>
        p['channels'][0]['routes'][0]['url'] = 'https://u:p@example/a',
  }.entries) {
    test('rejects ${mutation.key}', () {
      final value = fixture();
      mutation.value(value);
      expect(() => parse(value), throwsFormatException);
    });
  }
  test('bounds nesting and total bytes', () {
    expect(
      () => ResourcePackage.parse('${'[' * 17}0${']' * 17}'),
      throwsFormatException,
    );
    expect(
      () => ResourcePackage.parse(' ' * (ResourcePackage.maxBytes + 1)),
      throwsFormatException,
    );
  });
  test(
    'snapshot refresh is scoped, stable and retains favorite tombstones',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final store = ResourcePackageStore(database);
      await store.apply(
        providerId: 'local',
        package: parse(fixture()),
        address: 'https://host.example/package',
        create: true,
      );
      final before = await database.getAllChannels();
      expect(before, hasLength(2));
      await (database.update(database.channels)
            ..where((t) => t.id.equals(before.first.id)))
          .write(const db.ChannelsCompanion(favorite: Value(true)));
      final next = fixture();
      next['revision'] = '2';
      next['channels'][0]['routes'][0]['url'] =
          'https://media.example/changed.m3u8';
      await store.apply(
        providerId: 'local',
        package: parse(next),
        address: 'https://host.example/package',
        create: false,
      );
      final after = await database.getAllChannels();
      expect(after.map((c) => c.id).toSet(), before.map((c) => c.id).toSet());
      expect(after.singleWhere((c) => c.id == before.first.id).favorite, true);
      expect((await database.select(database.epgMappings).get()), hasLength(2));
      final keys = await database.channelPresentationKeys(after);
      expect(keys.values.toSet(), hasLength(1));
      await store.apply(
        providerId: 'other',
        package: parse(next),
        address: 'https://another.example/package',
        create: true,
      );
      final allKeys = await database.channelPresentationKeys(
        await database.getAllChannels(),
      );
      expect(allKeys.values.toSet(), hasLength(2));
      final empty = fixture();
      empty['channels'] = [];
      await store.apply(
        providerId: 'local',
        package: parse(empty),
        address: 'https://host.example/package',
        create: false,
      );
      final retired = await database.getChannelsForProvider('local');
      expect(retired, hasLength(1));
      expect(retired.single.favorite, true);
      expect(retired.single.streamUrl, isEmpty);
      final changed = fixture();
      changed['id'] = 'different';
      await expectLater(
        store.apply(
          providerId: 'other',
          package: parse(changed),
          address: 'https://another.example/package',
          create: false,
        ),
        throwsFormatException,
      );
      expect(await database.getChannelsForProvider('other'), hasLength(2));
      await database.deleteProvider('other');
      await expectLater(
        store.apply(
          providerId: 'other',
          package: parse(next),
          address: 'https://another.example/package',
          create: false,
        ),
        throwsStateError,
      );
      expect(
        (await database.getAllProviders()).any((p) => p.id == 'other'),
        false,
      );
    },
  );
  test('database write failure rolls back the whole new subscription', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.getAllProviders();
    await database.customStatement(
      "CREATE TRIGGER reject_test_route BEFORE INSERT ON channels WHEN NEW.stream_url LIKE '%/b.m3u8' BEGIN SELECT RAISE(ABORT, 'fixture rejection'); END",
    );
    await expectLater(
      ResourcePackageStore(database).apply(
        providerId: 'failed',
        package: parse(fixture()),
        address: 'https://host.example/package',
        create: true,
      ),
      throwsA(anything),
    );
    expect(await database.getAllProviders(), isEmpty);
    expect(await database.getAllChannels(), isEmpty);
    expect(await database.getAllEpgSources(), isEmpty);
  });
  test(
    'custom categories are available to navigation and candidate queries',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await ResourcePackageStore(database).apply(
        providerId: 'custom',
        package: parse(fixture()),
        address: '',
        create: true,
      );
      expect(await database.getUserSourceCategoryGroups(), ['新闻']);
      expect(await database.getChannelCategoryCandidates('新闻'), hasLength(2));
    },
  );
  test(
    'local bootstrap supports an explicit subscription URL and JSON errors hide content',
    () {
      final value = fixture();
      value['updateUrl'] = 'https://owner.example/catalog.bobtv';
      expect(parse(value).updateUrl!.host, 'owner.example');
      try {
        ResourcePackage.parse('{"secret": "private-token", BROKEN');
        fail('must reject');
      } on FormatException catch (error) {
        expect(error.toString(), isNot(contains('private-token')));
      }
    },
  );
  test(
    'source-only iOS does not seed channels or EPG before a route exists',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final catalog = WebsiteChannelCatalogService(
        database: database,
        api: BobTvApiClient(),
      );
      addTearDown(catalog.shutdown);
      expect(await catalog.importBundled(), 0);
      expect(await catalog.sync(), 0);
      final serverEpg = ServerEpgSyncService(database: database);
      addTearDown(serverEpg.shutdown);
      expect(await serverEpg.check(), false);
      final epg = EpgRefreshService(database);
      addTearDown(epg.shutdown);
      await epg.addDefaultSources();
      await epg.refreshAllSources();
      expect(await database.getAllProviders(), isEmpty);
      expect(await database.getAllChannels(), isEmpty);
      expect(await database.getAllEpgSources(), isEmpty);
    },
  );
  test(
    'deleting subscription removes its routes, guide and origin metadata',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final store = ResourcePackageStore(database);
      await store.apply(
        providerId: 'remove',
        package: parse(fixture()),
        address: 'https://host.example/package',
        create: true,
      );
      await store.remove('remove');
      expect(await database.getAllProviders(), isEmpty);
      expect(await database.getAllChannels(), isEmpty);
      expect(await database.getAllEpgSources(), isEmpty);
      expect(await database.getAllProviderOrigins(), isEmpty);
    },
  );
  test(
    'withdrawn guide stops syncing and subscription deletion cleans cached ownership',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final store = ResourcePackageStore(database);
      await store.apply(
        providerId: 'guide-owner',
        package: parse(fixture()),
        address: 'https://host.example/package',
        create: true,
      );
      final next = fixture();
      next['epgSources'] = [];
      next['channels'][0].remove('epg');
      await store.apply(
        providerId: 'guide-owner',
        package: parse(next),
        address: 'https://host.example/package',
        create: false,
      );
      expect((await database.getAllEpgSources()).single.enabled, false);
      expect(await database.select(database.epgMappings).get(), isEmpty);
      await store.remove('guide-owner');
      expect(await database.getAllEpgSources(), isEmpty);
    },
  );
  test('same name remote channel IDs keep separate cards', () {
    final keys = ChannelPresentationIdentity.keys([
      const ChannelPresentationRoute(
        id: 'user:channel1:route1',
        name: 'News',
        url: 'https://example/a',
      ),
      const ChannelPresentationRoute(
        id: 'user:channel2:route1',
        name: 'News',
        url: 'https://example/b',
      ),
    ]);
    expect(keys.values.toSet(), hasLength(2));
  });
  test(
    'direct user download, gzip, redirects and failure leave no implicit sources',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) async {
        if (r.uri.path == '/redirect') {
          r.response.statusCode = 302;
          r.response.headers.set('location', '/package');
        } else if (r.uri.path == '/bad') {
          r.response.headers.set('content-encoding', 'gzip');
          r.response.add([1, 2, 3]);
        } else if (r.uri.path == '/loop') {
          r.response.statusCode = 302;
          r.response.headers.set('location', '/loop');
        } else {
          r.response.headers.set('content-encoding', 'gzip');
          r.response.add(gzip.encode(utf8.encode(jsonEncode(fixture()))));
        }
        await r.response.close();
      });
      ServerEgress.installGuard();
      addTearDown(() => HttpOverrides.global = null);
      final base = 'http://127.0.0.1:${server.port}';
      expect(
        (await ResourcePackageClient().fetch('$base/redirect')).routeCount,
        2,
      );
      await expectLater(
        ResourcePackageClient().fetch('$base/bad'),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        ResourcePackageClient().fetch('$base/loop'),
        throwsFormatException,
      );
    },
  );
}
