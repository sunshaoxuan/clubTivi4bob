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
import 'package:clubtivi/data/services/manual_channel_category.dart';

class _CatalogApi extends BobTvApiClient {
  _CatalogApi(this.catalog);

  Map<String, Object?>? catalog;
  String version = '2026-09-28.1';
  int manifestCalls = 0;
  int downloads = 0;
  Object? failure;
  int? declaredRouteCount;
  @override
  Future<List<String>> fetchCatalogBlockedRoutes() async => const [];

  List<int> get bytes => gzip.encode(utf8.encode(jsonEncode(catalog)));

  @override
  Future<BobTvChannelCatalogManifest?> fetchChannelCatalogManifest() async {
    manifestCalls++;
    if (failure != null) throw failure!;
    if (catalog == null) return null;
    final digest = sha256.convert(bytes).toString();
    return BobTvChannelCatalogManifest(
      version: version,
      channelCount: (catalog!['channels'] as List).length,
      routeCount: declaredRouteCount ?? (catalog!['channels'] as List).fold<int>(
        0,
        (count, channel) => count + (channel['routes'] as List).length,
      ),
      snapshotPath: '/api/v1/channel-catalog/snapshots/$digest.json.gz',
      compressedBytes: bytes.length,
      sha256: digest,
    );
  }

  @override
  Future<List<int>> downloadChannelCatalog(
    BobTvChannelCatalogManifest manifest,
  ) async {
    downloads++;
    return bytes;
  }
}

Map<String, Object?> _catalog() => {
  'schemaVersion': 1,
  'version': '2026-09-28.1',
  'categories': [
    {'id': 'cn', 'parentId': null, 'name': '中国'},
    {'id': 'cn-cctv', 'parentId': 'cn', 'name': '央视'},
  ],
  'channels': [
    {
      'id': 'cctv-5-plus',
      'name': 'CCTV-5+ 体育赛事',
      'categoryId': 'cn-cctv',
      'sortOrder': 25,
      'epgId': 'cctv5plus',
      'logoUrl': null,
      'routes': [
        <String,Object?>{'id': 'route-one', 'url': 'https://media.example.org/live.m3u8'},
      ],
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('global other and radio imports preserve geography and separate media', () async {
    final payload = _catalog();
    payload['categories'] = [
      {'id': 'other', 'name': '其他', 'parentId': null},
      {'id': 'pending', 'name': '待识别', 'parentId': 'other'},
      {'id': 'radio', 'name': '广播', 'parentId': null},
      {'id': 'world', 'name': '国际', 'parentId': null},
      {'id': 'us', 'name': '美国', 'parentId': 'world'},
      {'id': 'tv', 'name': '电视', 'parentId': 'us'},
      {'id': 'news', 'name': '新闻', 'parentId': 'tv'},
    ];
    final template = (payload['channels'] as List).single as Map;
    payload['channels'] = [
      for (final (id, category, country) in [
        ('pending-station', 'pending', null), ('us-radio', 'radio', 'US'),
        ('cn-radio', 'radio', 'CN'), ('unknown-radio', 'radio', null),
        ('us-news', 'news', 'US'),
      ])
        {...template, 'id': id, 'categoryId': category, 'countryCode': country, 'routes': [
          {'id': 'route-$id', 'url': 'https://media.example.org/$id.m3u8'},
        ]},
    ];
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final service = WebsiteChannelCatalogService(database: database, api: _CatalogApi(payload));
    addTearDown(service.dispose);
    await service.sync();
    final rows = await database.getAllChannels();
    final groups = rows.map((row) => row.groupTitle).toSet();
    expect(groups, containsAll(['其他 / 待识别', '国际 / 美国 / 广播', '中国 / 广播', '其他 / 广播', '国际 / 美国 / 电视 / 新闻']));
    final other = await database.getChannelCategoryCandidates('其他');
    expect(other, hasLength(2));
    expect(WebsiteChannelCatalogService.countryForGroup('其他 / 待识别'), '未识别地区');
  });

  test('catalog imports English and Chinese country labels into one country', () async {
    final payload = _catalog();
    payload['categories'] = [
      {'id': 'world', 'parentId': null, 'name': '国际'},
      {'id': 'english', 'parentId': 'world', 'name': 'United States'},
      {'id': 'chinese', 'parentId': 'world', 'name': '美国'},
    ];
    final template = (payload['channels'] as List).single as Map;
    payload['channels'] = [
      for (final id in ['english', 'chinese'])
        {...template, 'id': id, 'categoryId': id, 'routes': [
          {'id': 'route-$id', 'url': 'https://media.example.org/$id.m3u8'},
        ]},
    ];
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final service = WebsiteChannelCatalogService(database: database, api: _CatalogApi(payload));
    addTearDown(service.dispose);
    await service.sync();
    final rows = await database.getAllChannels();
    expect(rows, hasLength(2));
    expect(rows.map((row) => row.groupTitle).toSet(), {'国际 / 美国'});
    expect(rows.map((row) => row.streamUrl).toSet(), {
      'https://media.example.org/english.m3u8',
      'https://media.example.org/chinese.m3u8',
    });
  });

  test('catalog import preserves country and region boundaries for duplicate cards', () async {
    final payload = _catalog();
    final template = (payload['channels'] as List).single as Map;
    payload['channels'] = [
      for (final id in ['one', 'two', 'other-region'])
        <String, Object?>{...template, 'id': id, 'countryCode': 'cn',
          'regionCode': id == 'other-region' ? 'south' : 'north',
          'routes': [{'id': 'route-$id', 'url': 'https://media.example.org/$id'}]},
    ];
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final api = _CatalogApi(payload);
    final service = WebsiteChannelCatalogService(database: database, api: api);
    addTearDown(() async { service.dispose(); await database.close(); });
    expect(await service.sync(), 3, reason: '${service.lastError}');
    // Upgraded databases refill context even when the catalog version is unchanged.
    await database.customStatement('DELETE FROM catalog_presentation_context');
    expect(await service.sync(), 3, reason: '${service.lastError}');
    var rows = await database.getAllChannels();
    var keys = await database.channelPresentationKeys(rows);
    expect(keys['bobtv-channel-catalog:route-one'], keys['bobtv-channel-catalog:route-two']);
    expect(keys.values.toSet(), hasLength(2));
    // A later authoritative metadata change rebuilds the grouping atomically.
    ((payload['channels'] as List)[1] as Map)['regionCode'] = 'east';
    payload['version'] = '2026-09-28.2';
    api.version = '2026-09-28.2';
    expect(await service.sync(), 3, reason: '${service.lastError}');
    rows = await database.getAllChannels();
    keys = await database.channelPresentationKeys(rows);
    expect(keys.values.toSet(), hasLength(3));
    expect(await database.pendingSharedEvents(), isEmpty);
  });

  test('one service retains multiple genre memberships and one favorite identity', () async {
    final payload = _catalog();
    payload['categories'] = [
      {'id': 'world', 'name': '国际', 'parentId': null},
      {'id': 'my', 'name': '马来西亚', 'parentId': 'world'},
      {'id': 'drama', 'name': '剧集', 'parentId': 'my'},
      {'id': 'movie', 'name': '电影', 'parentId': 'my'},
    ];
    final channel = (payload['channels'] as List).single as Map;
    channel['name'] = 'Astro AOD';
    channel['categoryId'] = 'drama';
    channel['categoryIds'] = ['drama', 'movie'];
    channel['routes'] = [
      {'id': 'one', 'url': 'https://media.example.org/aod'},
      {'id': 'two', 'url': 'https://media.example.org/aod2'},
    ];
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final service = WebsiteChannelCatalogService(database: database, api: _CatalogApi(payload));
    addTearDown(() async { service.dispose(); await database.close(); });
    expect(await service.sync(), 2, reason: '${service.lastError}');
    final rows = await database.getAllChannels();
    final groups = await database.publicCatalogCategoryGroups(rows.map((r) => r.id));
    expect(groups.values.every((g) => g.toSet().containsAll(
      ['国际 / 马来西亚 / 剧集', '国际 / 马来西亚 / 电影'])), isTrue);
    await database.addChannelToDefaultFavorites(rows.first.id);
    expect(await database.getAllFavoritedChannelIds(), hasLength(2));
    expect((await database.channelPresentationKeys(rows)).values.toSet(), hasLength(1));
    // An explicit pending classification must take precedence over old aliases.
    await (database.update(database.channels)..where((c) => c.id.equals(rows.first.id)))
        .write(const db.ChannelsCompanion(groupTitle: Value('国际 / 马来西亚 / 音乐')));
    expect((await database.publicCatalogCategoryGroups([rows.first.id])), isEmpty);
  });

  test('alternate classifications cannot cross countries or unknown categories', () async {
    for (final aliases in [<Object>['cn-cctv', 'missing'], <Object>['cn-cctv', 1],
        <Object>['cn-cctv', 'cn-cctv']]) {
      final payload = _catalog();
      ((payload['channels'] as List).single as Map)['categoryIds'] = aliases;
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final service = WebsiteChannelCatalogService(database: database, api: _CatalogApi(payload));
      try {
        expect(await service.sync(), 0);
        expect(service.state.value.error, isTrue);
        expect(await database.getAllChannels(), isEmpty);
      } finally { service.dispose(); await database.close(); }
    }
  });

  test('an offline deletion is not resurrected by a newer snapshot', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final api = _CatalogApi(_catalog());
    final service = WebsiteChannelCatalogService(database: database, api: api);
    addTearDown(() async {
      service.dispose();
      await database.close();
    });
    await service.sync();
    await database.deleteChannelsByIds(
      (await database.getAllChannels()).map((c) => c.id),
    );
    api.version = '2026-09-28.2';
    api.catalog = {..._catalog(), 'version': api.version};
    await service.sync();
    expect(await database.getAllChannels(), isEmpty);
    expect((await database.pendingSharedEvents()).single['kind'], 'delete');
  });

  test('older dated snapshots cannot overwrite a newer catalog', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final api = _CatalogApi({..._catalog(), 'version': '2026-10-04T01:00:00Z'})
      ..version = '2026-10-04T01:00:00Z';
    final service = WebsiteChannelCatalogService(database: database, api: api);
    addTearDown(() async {
      service.dispose();
      await database.close();
    });
    expect(await service.sync(), 1);
    api.version = '2026-10-03T01:00:00Z';
    api.catalog = {..._catalog(), 'version': api.version};
    expect(await service.sync(), 0);
    expect(service.state.value.error, isTrue);
    expect(await database.getAllChannels(), hasLength(1));
  });

  test('acknowledged local category yields to newer shared revision', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final api = _CatalogApi(_catalog());
    final service = WebsiteChannelCatalogService(database: database, api: api);
    addTearDown(() async {
      service.dispose();
      await database.close();
    });
    await service.sync();
    const url = 'https://media.example.org/live.m3u8';
    await database.setManualChannelCategory([
      url,
    ], ChannelCategoryDestination(['美国', '新闻']));
    for (final e in await database.pendingSharedEvents()) {
      await database.acknowledgeSharedEvent(e['id'] as String);
    }
    await database.setSharedRouteState(url, 2);
    api.version = '2026-09-28.2';
    api.catalog = {
      ..._catalog(),
      'version': api.version,
      'categories': [
        {'id': 'us', 'name': '美国', 'parentId': null},
        {'id': 'religion', 'name': '宗教', 'parentId': 'us'},
      ],
    };
    final channel = (api.catalog!['channels'] as List).single;
    channel['categoryId'] = 'religion';
    (channel['routes'] as List).single['revision'] = 3;
    await service.sync();
    expect((await database.getAllChannels()).single.groupTitle, '国际 / 美国 / 宗教');
    expect(await ManualChannelCategory.load(), isEmpty);
    expect(await database.pendingSharedEvents(), isEmpty);
  });

  test(
    'packaged starter initializes an empty database without network access',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final service = WebsiteChannelCatalogService(
        database: database,
        api: _CatalogApi(null),
      );
      addTearDown(() async {
        service.dispose();
        await database.close();
      });
      expect(
        await service.importBundled(),
        greaterThan(0),
        reason: '${service.lastError}',
      );
      final rows = await database.getChannelsForProvider(
        WebsiteChannelCatalogService.providerId,
      );
      expect(rows.where((row) => row.groupTitle == '中国 / 央视'), isNotEmpty);
    },
  );

  test(
    'fresh installation receives server verification without a local scan',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final catalog = _catalog();
      ((catalog['channels'] as List).single['routes'] as List)
          .single['lastPlayableAt'] = DateTime.now()
          .toUtc()
          .toIso8601String();
      final service = WebsiteChannelCatalogService(
        database: database,
        api: _CatalogApi(catalog),
      );
      addTearDown(() async {
        service.dispose();
        await database.close();
      });
      expect(await service.sync(), 1);
      final checks = await database.getAllStreamChecks();
      expect(checks.single.lastSuccessAt, isNotNull);
      expect(checks.single.consecutiveFailures, 0);
      expect(checks.single.retired, isFalse);
    },
  );

  test('catalog route ID migration preserves favorite lists by URL', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final api = _CatalogApi(_catalog());
    final service = WebsiteChannelCatalogService(database: database, api: api);
    addTearDown(() async {
      service.dispose();
      await database.close();
    });
    await service.sync();
    final old = (await database.getChannelsForProvider(
      WebsiteChannelCatalogService.providerId,
    )).single;
    await database.addChannelToDefaultFavorites(old.id);
    api.version = '2026-09-28.2';
    api.catalog = {..._catalog(), 'version': api.version};
    ((api.catalog!['channels'] as List).single['routes'] as List).single['id'] =
        'route-renamed';
    await service.sync();
    final favorites = await database.getChannelsInList('default');
    expect(favorites.single.streamUrl, old.streamUrl);
    expect(favorites.single.id, endsWith(':route-renamed'));
  });

  test(
    'imports a classified website route and preserves its favorite',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final api = _CatalogApi(_catalog());
      final service = WebsiteChannelCatalogService(
        database: database,
        api: api,
      );
      addTearDown(() async {
        service.dispose();
        await database.close();
      });
      expect(await service.sync(), 1, reason: '${service.lastError}');
      var channels = await database.getChannelsForProvider(
        WebsiteChannelCatalogService.providerId,
      );
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
        WebsiteChannelCatalogService.providerId,
      );
      expect(channels.single.favorite, isTrue);
      api.catalog = null;
      expect(await service.sync(), 0);
      expect(
        (await database.getChannelsForProvider(
          WebsiteChannelCatalogService.providerId,
        )).length,
        1,
      );
    },
  );

  test('excluded routes do not reject valid peers or break raw route counts', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final payload = _mixedCatalog();
    final api = _CatalogApi(payload);
    final service = WebsiteChannelCatalogService(database: database, api: api);
    addTearDown(() async { service.dispose(); await database.close(); });
    expect(await service.sync(), 1, reason: '${service.lastError}');
    expect(service.state.value.complete, isTrue);
    expect(service.state.value.error, isFalse);
    expect((await database.getAllChannels()).single.name, 'CCTV-5+ 体育赛事');
    expect(await database.sharedCatalogVersion(), api.version);
    expect(await service.sync(), 0);
    expect(api.downloads, 1);
    expect(service.state.value.error, isFalse);
  });

  test('malformed excluded routes still reject the snapshot atomically', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final payload = _mixedCatalog();
    (payload['channels'] as List)[1]['routes'][0]['url'] = 'http://127.0.0.1/private';
    final service = WebsiteChannelCatalogService(database: database, api: _CatalogApi(payload));
    addTearDown(() async { service.dispose(); await database.close(); });
    expect(await service.sync(), 0);
    expect(service.state.value.error, isTrue);
    expect(await database.getAllProviders(), isEmpty);
  });

  test('filtering cannot conceal an incorrect source route count', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final api = _CatalogApi(_mixedCatalog())..declaredRouteCount = 2;
    final service = WebsiteChannelCatalogService(database: database, api: api);
    addTearDown(() async { service.dispose(); await database.close(); });
    expect(await service.sync(), 0);
    expect(service.state.value.error, isTrue);
    expect(await database.getAllProviders(), isEmpty);
  });

  test('all-excluded snapshot preserves the previously usable catalog', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final api = _CatalogApi(_catalog());
    final service = WebsiteChannelCatalogService(database: database, api: api);
    addTearDown(() async { service.dispose(); await database.close(); });
    expect(await service.sync(), 1);
    api.version = '2026-09-28.2';
    api.catalog = {..._catalog(), 'version': api.version};
    (api.catalog!['channels'] as List).single['name'] = '购物频道';
    expect(await service.sync(), 0);
    expect(service.state.value.error, isTrue);
    expect((await database.getAllChannels()).single.name, 'CCTV-5+ 体育赛事');
    expect(await database.sharedCatalogVersion(), '2026-09-28.1');
  });

  test('route hints during backoff keep retry status stable and do not refetch', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final api = _CatalogApi(_catalog())..failure = const FormatException('fixture');
    var clock = DateTime.utc(2026, 10, 24);
    final service = WebsiteChannelCatalogService(database: database, api: api, now: () => clock);
    addTearDown(() async { service.dispose(); await database.close(); });
    var notifications = 0;
    service.state.addListener(() => notifications++);
    await service.sync();
    final failedNotifications = notifications;
    for (var i = 0; i < 20; i++) { await service.sync(); }
    expect(api.manifestCalls, 1);
    expect(notifications, failedNotifications);
    expect(service.state.value.error, isTrue);
    api.failure = null;
    clock = clock.add(const Duration(seconds: 30));
    expect(await service.sync(), 1);
    expect(service.state.value.error, isFalse);
    expect(api.manifestCalls, 2);
    await service.sync();
    expect(api.manifestCalls, 3);
  });

  test('catalog backoff respects upstream Retry-After', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final api = _CatalogApi(_catalog())..failure = const BobTvApiException(
      'fixture', statusCode: 429, retryAfter: Duration(minutes: 5));
    var clock = DateTime.utc(2026, 10, 24);
    final service = WebsiteChannelCatalogService(database: database, api: api, now: () => clock);
    addTearDown(() async { service.dispose(); await database.close(); });
    await service.sync();
    clock = clock.add(const Duration(minutes: 4));
    await service.sync();
    expect(api.manifestCalls, 1);
    clock = clock.add(const Duration(minutes: 1));
    api.failure = null;
    expect(await service.sync(), 1);
  });

  test(
    'rejects malformed snapshot before touching the local database',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final payload = _catalog();
      ((payload['channels'] as List).single['routes'] as List).single['url'] =
          'http://127.0.0.1/private';
      final service = WebsiteChannelCatalogService(
        database: database,
        api: _CatalogApi(payload),
      );
      addTearDown(() async {
        service.dispose();
        await database.close();
      });
      expect(await service.sync(), 0);
      expect(service.state.value.error, isTrue);
      expect(await database.getAllProviders(), isEmpty);
    },
  );

  test('two installations receive the same shared routes', () async {
    final first = db.AppDatabase.forTesting(NativeDatabase.memory());
    final second = db.AppDatabase.forTesting(NativeDatabase.memory());
    final api = _CatalogApi(_catalog());
    final firstSync = WebsiteChannelCatalogService(database: first, api: api);
    final secondSync = WebsiteChannelCatalogService(
      database: second,
      api: _CatalogApi(_catalog()),
    );
    addTearDown(() async {
      firstSync.dispose();
      secondSync.dispose();
      await first.close();
      await second.close();
    });
    expect(await firstSync.sync(), 1);
    expect(await secondSync.sync(), 1);
    final firstRoutes = await first.getChannelsForProvider(
      WebsiteChannelCatalogService.providerId,
    );
    final secondRoutes = await second.getChannelsForProvider(
      WebsiteChannelCatalogService.providerId,
    );
    expect(
      firstRoutes.map((route) => (route.id, route.streamUrl)),
      secondRoutes.map((route) => (route.id, route.streamUrl)),
    );
    expect(
      WebsiteChannelCatalogService.showInSimpleMode(
        sharedCatalogAvailable: true,
        personalCollection: false,
        providerId: WebsiteChannelCatalogService.providerId,
      ),
      isTrue,
    );
    expect(
      WebsiteChannelCatalogService.showInSimpleMode(
        sharedCatalogAvailable: true,
        personalCollection: false,
        providerId: 'hotel-myiptv-ipv4',
      ),
      isFalse,
    );
    expect(
      WebsiteChannelCatalogService.showInSimpleMode(
        sharedCatalogAvailable: true,
        personalCollection: true,
        providerId: 'hotel-myiptv-ipv4',
      ),
      isTrue,
    );
  });

  test(
    'withdrawn shared routes leave every device, even when favorited',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final catalog = _catalog();
      final routes = ((catalog['channels'] as List).single['routes'] as List);
      routes.add({
        'id': 'route-two',
        'url': 'https://media.example.org/alt.m3u8',
      });
      final api = _CatalogApi(catalog);
      final service = WebsiteChannelCatalogService(
        database: database,
        api: api,
      );
      addTearDown(() async {
        service.dispose();
        await database.close();
      });
      expect(await service.sync(), 2);
      final original = (await database.getChannelsForProvider(
        WebsiteChannelCatalogService.providerId,
      )).firstWhere((route) => route.id.endsWith('route-one'));
      await database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: original.id,
          providerId: original.providerId,
          name: original.name,
          streamUrl: original.streamUrl,
          favorite: const Value(true),
        ),
      ]);
      routes.removeAt(0);
      api.version = '2026-09-28.2';
      catalog['version'] = api.version;
      expect(await service.sync(), 1);
      final remaining = await database.getChannelsForProvider(
        WebsiteChannelCatalogService.providerId,
      );
      expect(remaining.map((route) => route.id), [
        '${WebsiteChannelCatalogService.providerId}:route-two',
      ]);
    },
  );

  test('locally blocked route stays blocked after website refresh', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    const url = 'https://media.example.org/live.m3u8';
    await database.blockAndDeleteStreamUrl(
      url,
      reason: 'user_reported_wrong_content',
    );
    final api = _CatalogApi(_catalog());
    final service = WebsiteChannelCatalogService(database: database, api: api);
    addTearDown(() async {
      service.dispose();
      await database.close();
    });
    expect(await service.sync(), 0);
    expect(
      await database.getChannelsForProvider(
        WebsiteChannelCatalogService.providerId,
      ),
      isEmpty,
    );
    expect(await service.sync(), 0);
    expect(service.state.value.error, isFalse);
  });

  test(
    'shared categories include routes without matching name keywords',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.upsertProvider(
        db.ProvidersCompanion.insert(
          id: WebsiteChannelCatalogService.providerId,
          name: 'BobTV 网站频道',
          type: 'catalog',
        ),
      );
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
      expect(
        (await database.getChannelCategoryCandidates(
          '广东',
        )).map((channel) => channel.name),
        contains('Morning Live'),
      );
      expect(
        (await database.getChannelCategoryCandidates(
          '国际',
        )).map((channel) => channel.name),
        contains('World One'),
      );
    },
  );
}

Map<String, Object?> _mixedCatalog() {
  final payload = _catalog();
  payload['categories'] = [
    ...(payload['categories'] as List),
    {'id': 'uk', 'parentId': null, 'name': '英国'},
    {'id': 'shop', 'parentId': 'uk', 'name': '购物'},
  ];
  final template = Map<String, Object?>.from((payload['channels'] as List).single);
  payload['channels'] = [
    ...(payload['channels'] as List),
    {...template, 'id': 'shop-channel', 'name': 'Luxury', 'categoryId': 'shop',
      'routes': [{'id': 'shop-route', 'url': 'https://media.example.org/shopping.m3u8'}]},
    {...template, 'id': 'platform-channel', 'name': 'Example',
      'routes': [{'id': 'platform-route', 'url': 'https://video.huya.com/live.m3u8'}]},
  ];
  return payload;
}
