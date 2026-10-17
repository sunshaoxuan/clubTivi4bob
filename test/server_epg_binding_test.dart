import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/models/catalog_epg_identity.dart';
import 'package:clubtivi/data/models/server_epg_snapshot.dart';
import 'package:clubtivi/data/models/channel.dart';
import 'package:clubtivi/data/models/epg.dart' as epg;
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/website_channel_catalog_service.dart';
import 'package:clubtivi/data/services/server_epg_sync_service.dart';
import 'package:clubtivi/data/services/server_epg_binding.dart';
import 'package:clubtivi/data/services/epg_auto_mapper.dart';

final _at = DateTime.utc(2026, 10, 16, 6);
final _epoch = _at.millisecondsSinceEpoch ~/ 1000;
const _localId = '$publicCatalogProviderId:route-one';
Map<String, dynamic> _identity() => {
  'id': 'channel-test',
  'name': 'CCTV-5+ 体育赛事',
  'epgId': 'CCTV5+',
  'countryCode': 'cn',
  'regionCode': '央视',
};

class _Api extends BobTvApiClient {
  Map<String, dynamic> catalogIdentity = _identity();
  Map<String, dynamic> epgIdentity = _identity();
  String catalogVersion = '2026-10-16T06:00:00Z';
  int catalogDownloads = 0;
  Map<String, dynamic> get catalog => {
    'schemaVersion': 1,
    'version': catalogVersion,
    'categories': [
      {'id': 'cn', 'name': '中国', 'parentId': null},
      {'id': 'sports', 'name': '体育', 'parentId': 'cn'},
    ],
    'channels': [
      {
        ...catalogIdentity,
        'categoryId': 'sports',
        'routes': [
          {'id': 'route-one', 'url': 'https://media.example.org/live.m3u8'},
        ],
      },
    ],
  };
  List<int> get catalogBytes => gzip.encode(utf8.encode(jsonEncode(catalog)));
  Map<String, dynamic> get epgPayload => {
    'schemaVersion': 1,
    'version': 'epg-${sha256.convert(utf8.encode(jsonEncode(epgIdentity)))}',
    'channels': [
      {
        ...epgIdentity,
        'sourceId': 'reviewed-upstream',
        'originalChannelId': 'cctv5plus-exact',
        'confidence': 1.0,
        'catalogIdentityHash': catalogEpgIdentityHash(epgIdentity),
      },
    ],
    'programmes': [
      for (var i = 0; i < 3; i++)
        {
          'channelId': epgIdentity['id'],
          'sourceId': 'reviewed-upstream',
          'originalChannelId': 'cctv5plus-exact',
          'title': 'Synthetic programme $i',
          'startUtc': _epoch - 1800 + i * 3600,
          'stopUtc': _epoch + 1800 + i * 3600,
          'provenance': {'fixture': true},
        },
    ],
  };
  List<int> get epgBytes => gzip.encode(utf8.encode(jsonEncode(epgPayload)));
  @override
  Future<List<String>> fetchCatalogBlockedRoutes() async => [];
  @override
  Future<BobTvChannelCatalogManifest?> fetchChannelCatalogManifest() async {
    final hash = sha256.convert(catalogBytes).toString();
    return BobTvChannelCatalogManifest(
      version: catalogVersion,
      channelCount: 1,
      routeCount: 1,
      snapshotPath: '/api/v1/channel-catalog/snapshots/$hash.json.gz',
      compressedBytes: catalogBytes.length,
      sha256: hash,
    );
  }

  @override
  Future<List<int>> downloadChannelCatalog(
    BobTvChannelCatalogManifest manifest,
  ) async {
    catalogDownloads++;
    return catalogBytes;
  }

  @override
  Future<ServerEpgManifest?> fetchEpgManifest() async {
    final hash = sha256.convert(epgBytes).toString();
    return ServerEpgManifest.parse(<String, dynamic>{
      'schemaVersion': 1,
      'version': epgPayload['version'],
      'sha256': hash,
      'snapshotUrl': '/api/v1/epg/snapshots/$hash.json.gz',
      'compressedBytes': epgBytes.length,
      'channelCount': 1,
      'programmeCount': 3,
      'generatedAt': _at.toIso8601String(),
      'coverageStartUtc': _epoch - 1800,
      'coverageEndUtc': _epoch + 9000,
    });
  }

  @override
  Future<List<int>> downloadEpgSnapshot(ServerEpgManifest manifest) async =>
      epgBytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late _Api api;
  late WebsiteChannelCatalogService catalog;
  late ServerEpgSyncService receiver;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    api = _Api();
    catalog = WebsiteChannelCatalogService(database: database, api: api);
    receiver = ServerEpgSyncService(
      database: database,
      api: api,
      now: () => _at,
      decode: decodeServerEpg,
    );
  });
  tearDown(() async {
    catalog.dispose();
    receiver.dispose();
    api.close();
    await database.close();
  });
  test(
    'fingerprint matches Python sorted UTF-8 JSON and preserves region and plus',
    () {
      expect(
        catalogEpgIdentityHash(_identity()),
        '0c9f8c94f862ba9f8662d6886cef770b69e879c7ff63916d8c2ca5d71e7da11f',
      );
      for (final patch in [
        {'name': 'CCTV-5 体育'},
        {'epgId': 'CCTV5'},
        {'regionCode': 'other-region'},
        {'countryCode': 'tw'},
        {'name': 'CCTV-5+ 体育赛事 +1'},
      ]) {
        expect(
          catalogEpgIdentityHash({..._identity(), ...patch}),
          isNot(catalogEpgIdentityHash(_identity())),
        );
      }
    },
  );
  test(
    'catalog then guide links an exact public route and loads its programmes',
    () async {
      await catalog.sync();
      await receiver.check();
      final mapping = (await database.getAllMappings()).single;
      expect(mapping.channelId, _localId);
      expect(mapping.source, 'server');
      expect(mapping.epgChannelId, '${serverEpgSourceId}_channel-test');
      expect(mapping.epgSourceId, serverEpgSourceId);
      expect(
        await database.getUpcomingProgrammes(
          epgChannelId: mapping.epgChannelId,
          at: _at,
          limit: 3,
        ),
        hasLength(3),
      );
    },
  );
  test('unchanged guide repairs a previous raw-ID managed mapping', () async {
    await catalog.sync();
    expect(await receiver.check(), isTrue);
    await database.customStatement(
      "UPDATE epg_mappings SET epg_channel_id='channel-test' WHERE source='server' AND locked=0",
    );
    expect(await receiver.check(forceVersionCheck: true), isFalse);
    final mapping = (await database.getAllMappings()).single;
    expect(mapping.epgChannelId, '${serverEpgSourceId}_channel-test');
    expect(
      await database.getUpcomingProgrammes(
        epgChannelId: mapping.epgChannelId,
        at: _at,
        limit: 3,
      ),
      hasLength(3),
    );
  });
  test(
    'guide arriving before catalog is linked by later catalog import',
    () async {
      await receiver.check();
      expect(await database.getAllMappings(), isEmpty);
      await catalog.sync();
      expect(await database.getAllMappings(), hasLength(1));
    },
  );
  test(
    'upgraded client backfills identity metadata even with unchanged catalog version',
    () async {
      await catalog.sync();
      await receiver.check();
      await database.customStatement('DELETE FROM catalog_epg_routes');
      await database.customStatement(
        'DELETE FROM catalog_epg_identity_version',
      );
      expect(await catalog.sync(), 1);
      expect(api.catalogDownloads, 2);
      expect(
        await database.customSelect('SELECT * FROM catalog_epg_routes').get(),
        hasLength(1),
      );
      expect(await catalog.sync(), 0);
      expect(api.catalogDownloads, 2);
    },
  );
  for (final field in ['countryCode', 'regionCode', 'name', 'epgId']) {
    test('matching ID cannot override different $field context', () async {
      api.epgIdentity[field] = field == 'epgId'
          ? 'CCTV5'
          : field == 'name'
          ? 'CCTV-5+ 体育赛事 +1'
          : 'other';
      await catalog.sync();
      await receiver.check();
      expect(await database.getAllMappings(), isEmpty);
    });
  }
  test(
    'manual private-source mapping remains locked through new guide imports',
    () async {
      await catalog.sync();
      await database.upsertEpgSource(
        db.EpgSourcesCompanion.insert(
          id: 'private',
          name: 'Private',
          url: 'https://example.org/private.xml',
        ),
      );
      await database.upsertMapping(
        db.EpgMappingsCompanion.insert(
          channelId: _localId,
          providerId: publicCatalogProviderId,
          epgChannelId: 'private-exact',
          epgSourceId: 'private',
          source: const Value('manual'),
          locked: const Value(true),
        ),
      );
      await receiver.check();
      await ServerEpgBinding(database).reconcile();
      final mapping = (await database.getAllMappings()).single;
      expect(mapping.epgSourceId, 'private');
      expect(mapping.locked, isTrue);
    },
  );
  test('local identity drift removes only automatic server mapping', () async {
    await catalog.sync();
    await receiver.check();
    await database.customStatement(
      "UPDATE channels SET name='Different channel' WHERE id=?",
      [_localId],
    );
    await ServerEpgBinding(database).reconcile();
    expect(await database.getAllMappings(), isEmpty);
  });
  test('unmodified binding is idempotent with no mapping rewrites', () async {
    await catalog.sync();
    await receiver.check();
    await database.customStatement(
      "CREATE TRIGGER no_mapping_rewrites BEFORE UPDATE ON epg_mappings BEGIN SELECT RAISE(ABORT,'unexpected rewrite'); END",
    );
    expect(await ServerEpgBinding(database).reconcile(), 1);
    expect(await ServerEpgBinding(database).reconcile(), 1);
  });
  test(
    'catalog fingerprint change invalidates old guide without affecting playback rows',
    () async {
      await catalog.sync();
      await receiver.check();
      api.catalogVersion = '2026-10-16T06:01:00Z';
      api.catalogIdentity['regionCode'] = 'other';
      await catalog.sync();
      expect(await database.getAllMappings(), isEmpty);
      expect(
        (await database.getAllChannels()).single.streamUrl,
        'https://media.example.org/live.m3u8',
      );
    },
  );
  test('managed guide is excluded from the legacy fuzzy matcher', () {
    final result = EpgAutoMapper().findCandidates(
      channel: const Channel(
        id: 'private',
        providerId: 'private',
        name: 'CCTV-5+ 体育赛事',
        tvgId: 'channel-test',
        streamUrl: 'https://example.org/live.m3u8',
      ),
      epgChannels: const [
        epg.EpgChannel(
          id: 'channel-test',
          sourceId: serverEpgSourceId,
          displayNames: ['CCTV-5+ 体育赛事'],
        ),
      ],
      epgSourceId: serverEpgSourceId,
    );
    expect(result, isEmpty);
  });

  test(
    'managed entries in a mixed legacy source list cannot bypass exact binding',
    () {
      final result = EpgAutoMapper().findCandidates(
        channel: const Channel(
          id: 'private',
          providerId: 'private',
          name: 'CCTV-5+ 体育赛事',
          tvgId: 'channel-test',
          streamUrl: 'https://example.org/live.m3u8',
        ),
        epgChannels: const [
          epg.EpgChannel(
            id: 'channel-test',
            sourceId: serverEpgSourceId,
            displayNames: ['CCTV-5+ 体育赛事'],
          ),
          epg.EpgChannel(
            id: 'unrelated',
            sourceId: 'legacy',
            displayNames: ['Unrelated'],
          ),
        ],
        epgSourceId: 'legacy',
        exactOnly: true,
      );
      expect(result, isEmpty);
    },
  );

  test(
    'legacy auto-mapper cannot replace an existing exact server binding',
    () {
      var writes = 0;
      final stats = EpgAutoMapper().mapAll(
        channels: const [
          Channel(
            id: 'local',
            providerId: 'provider',
            name: 'CCTV5+',
            streamUrl: 'https://example.org/live.m3u8',
          ),
        ],
        epgChannels: const [],
        existingMappings: const {
          'local:provider': epg.EpgMapping(
            playlistChannelId: 'local',
            providerId: 'provider',
            epgChannelId: 'channel-test',
            epgSourceId: serverEpgSourceId,
            confidence: 1,
            source: epg.MappingSource.auto,
          ),
        },
        epgSourceId: 'legacy',
        onMapping: (_) => writes++,
      );
      expect(writes, 0);
      expect(stats.mapped, 1);
    },
  );

  test(
    'catalog identity-write failure rolls back catalog rows and version',
    () async {
      await catalog.sync();
      final before =
          (await database
                  .customSelect('SELECT identity_hash FROM catalog_epg_routes')
                  .getSingle())
              .read<String>('identity_hash');
      await database.customStatement(
        "CREATE TRIGGER reject_new_identity BEFORE INSERT ON catalog_epg_routes BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      api.catalogVersion = '2026-10-16T06:01:00Z';
      api.catalogIdentity['name'] = 'New public name';
      expect(await catalog.sync(), 0);
      expect(catalog.state.value.error, isTrue);
      expect((await database.getAllChannels()).single.name, 'CCTV-5+ 体育赛事');
      expect(await database.sharedCatalogVersion(), '2026-10-16T06:00:00Z');
      expect(
        (await database
                .customSelect('SELECT identity_hash FROM catalog_epg_routes')
                .getSingle())
            .read<String>('identity_hash'),
        before,
      );
    },
  );
}
