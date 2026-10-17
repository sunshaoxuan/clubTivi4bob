import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/models/catalog_epg_identity.dart';
import 'package:clubtivi/data/models/server_epg_snapshot.dart';
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/server_epg_binding.dart';
import 'package:clubtivi/data/services/server_epg_sync_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

// The Python publisher authored these exact bytes in a disposable fixture DB.
// All programme titles, permissions and public-node checks are test-only.
class _PublishedFixtureApi extends BobTvApiClient {
  _PublishedFixtureApi(this.versions);
  final List<Map<String, dynamic>> versions;
  int index = 0, checks = 0, downloads = 0;
  bool corrupt = false;

  @override
  Future<ServerEpgManifest?> fetchEpgManifest() async {
    checks++;
    return ServerEpgManifest.parse(versions[index]['manifest']);
  }

  @override
  Future<List<int>> downloadEpgSnapshot(ServerEpgManifest manifest) async {
    downloads++;
    return corrupt
        ? [0, 1, 2]
        : base64Decode(versions[index]['compressedBase64'] as String);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture =
      jsonDecode(
            File('test/fixtures/server_epg_contract.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final versions = (fixture['versions'] as List)
      .map((value) => Map<String, dynamic>.from(value as Map))
      .toList();
  final identity = Map<String, dynamic>.from(fixture['catalogIdentity'] as Map);
  const routeId = '$publicCatalogProviderId:contract-fixture-route';
  late db.AppDatabase database;
  late _PublishedFixtureApi api;
  late ServerEpgSyncService receiver;
  late DateTime clock;

  DateTime timeOf(int index) => DateTime.fromMillisecondsSinceEpoch(
    (versions[index]['checkedAtUtc'] as int) * 1000,
    isUtc: true,
  );

  setUp(() async {
    expect(fixture['fixtureOnly'], isTrue);
    expect(fixture['productionPublications'], 0);
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    api = _PublishedFixtureApi(versions);
    clock = timeOf(0);
    // Exercise the production background-isolate decoder without an override.
    receiver = ServerEpgSyncService(
      database: database,
      api: api,
      now: () => clock,
    );
    await database.upsertProvider(
      db.ProvidersCompanion.insert(
        id: publicCatalogProviderId,
        name: 'Authored contract fixture',
        type: 'm3u',
      ),
    );
    await database.upsertChannels([
      db.ChannelsCompanion.insert(
        id: routeId,
        providerId: publicCatalogProviderId,
        name: identity['name'] as String,
        streamUrl: 'https://fixture.example.org/never-opened',
        tvgId: Value(identity['epgId'] as String),
        groupTitle: const Value('Contract fixture'),
      ),
    ]);
    await database.transaction(() async {
      await ServerEpgBinding(database).replaceCatalogIdentities(
        'authored-contract-fixture',
        [
          {
            'routeId': 'contract-fixture-route',
            'catalogChannelId': identity['id'],
            'catalogIdentityHash': catalogEpgIdentityHash(identity),
            'name': identity['name'],
            'epgId': identity['epgId'],
            'group': 'Contract fixture',
          },
        ],
      );
    });
    await database.upsertEpgSource(
      db.EpgSourcesCompanion.insert(
        id: 'private-fixture',
        name: 'Private fixture',
        url: 'https://private.example.org/never-fetched',
      ),
    );
    await database.insertEpgProgrammes([
      db.EpgProgrammesCompanion.insert(
        epgChannelId: 'private-fixture_exact',
        sourceId: 'private-fixture',
        title: 'Private authored fixture',
        start: clock.subtract(const Duration(hours: 1)),
        stop: clock.add(const Duration(hours: 3)),
      ),
    ]);
  });

  tearDown(() async {
    receiver.dispose();
    api.close();
    await database.close();
  });

  Future<List<String>> managedTitles() async =>
      (await (database.select(
            database.epgProgrammes,
          )..where((row) => row.sourceId.equals(serverEpgSourceId))).get())
          .map((row) => row.title)
          .toList();

  Future<String> installedVersion() async =>
      (jsonDecode(
                (await database
                        .customSelect(
                          'SELECT manifest FROM server_epg_receipt WHERE id=1',
                        )
                        .getSingle())
                    .read<String>('manifest'),
              )
              as Map)['version']
          as String;

  test(
    'two Python-emitted versions import and bind without rewriting routes',
    () async {
      final routes = await database.select(database.channels).get();
      receiver.start();
      expect(await receiver.check(), isTrue);
      expect(await managedTitles(), versions[0]['expectedTitles']);
      expect(
        await installedVersion(),
        (versions[0]['manifest'] as Map)['version'],
      );
      final mapping = (await database.getMappingsForChannelIds({
        routeId,
      })).single;
      expect(mapping.epgChannelId, '${serverEpgSourceId}_${identity['id']}');
      expect(mapping.epgSourceId, serverEpgSourceId);
      expect(mapping.source, 'server');
      expect(
        await database.getUpcomingProgrammes(
          epgChannelId: mapping.epgChannelId,
          at: clock,
          limit: 3,
        ),
        hasLength(2),
      );
      expect(receiver.state.value.attributions.single.sourceId, 'fixture');

      api.index = 1;
      clock = timeOf(1);
      receiver.onAppResumed();
      expect(await receiver.check(), isTrue);
      expect(await managedTitles(), versions[1]['expectedTitles']);
      expect(
        await installedVersion(),
        (versions[1]['manifest'] as Map)['version'],
      );
      expect(await database.select(database.channels).get(), routes);
      expect(await receiver.check(forceVersionCheck: true), isFalse);
      expect(api.downloads, 2);
    },
  );

  test(
    'Python-emitted guide preserves a locked manual mapping and private rows',
    () async {
      await database.upsertMapping(
        db.EpgMappingsCompanion.insert(
          channelId: routeId,
          providerId: publicCatalogProviderId,
          epgChannelId: 'exact',
          epgSourceId: 'private-fixture',
          source: const Value('manual'),
          locked: const Value(true),
        ),
      );
      final mappings = await database.getMappingsForChannelIds({routeId});
      final privateRows = await (database.select(
        database.epgProgrammes,
      )..where((row) => row.sourceId.equals('private-fixture'))).get();
      expect(await receiver.check(), isTrue);
      api.index = 1;
      clock = timeOf(1);
      expect(await receiver.check(), isTrue);
      expect(await database.getMappingsForChannelIds({routeId}), mappings);
      expect(
        await (database.select(
          database.epgProgrammes,
        )..where((row) => row.sourceId.equals('private-fixture'))).get(),
        privateRows,
      );
    },
  );

  test(
    'damaged Python snapshot retains cache and reconnect installs the valid version',
    () async {
      expect(await receiver.check(), isTrue);
      final original = await installedVersion();
      api.index = 1;
      api.corrupt = true;
      clock = timeOf(1);
      expect(await receiver.check(forceVersionCheck: true), isFalse);
      expect(await installedVersion(), original);
      expect(await managedTitles(), versions[0]['expectedTitles']);
      expect(receiver.state.value.error, 'invalid_epg_data');
      api.corrupt = false;
      clock = clock.add(const Duration(seconds: 31));
      receiver.onNetworkRestored();
      expect(await receiver.check(), isTrue);
      expect(
        await installedVersion(),
        (versions[1]['manifest'] as Map)['version'],
      );
      expect(await managedTitles(), versions[1]['expectedTitles']);
      expect(api.downloads, 3);
    },
  );
}
