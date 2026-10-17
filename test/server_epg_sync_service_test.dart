import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/models/server_epg_snapshot.dart';
import 'package:clubtivi/data/models/catalog_epg_identity.dart';
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/server_epg_sync_service.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

// Synthetic fixtures are kept in temporary databases and never published.
final _at = DateTime.utc(2026, 10, 16, 6);
final _epoch = _at.millisecondsSinceEpoch ~/ 1000;
Map<String, dynamic> _credit({String label = 'TVmaze'}) => {
  'sourceId': 'reviewed-source',
  'sourceLabel': label,
  'attributionUrl': 'https://www.tvmaze.com/',
  'licenseUrl': 'https://creativecommons.org/licenses/by-sa/4.0/',
  'modificationNotice': 'UTC normalization and explicit-runtime conversion.',
  'shareAlikeRequired': true,
};
Map<String, dynamic> _licensed(String version, {String label = 'TVmaze'}) {
  final payload = _payload(version);
  payload['dataAttributions'] = [_credit(label: label)];
  for (final programme in payload['programmes'] as List) {
    programme['provenance']['dataLicense'] = 'CC BY-SA 4.0';
  }
  return payload;
}

Map<String, dynamic> _payload(String label) => {
  'schemaVersion': 1,
  'version': 'epg-${sha256.convert(utf8.encode(label))}',
  'channels': [
    {
      'id': 'catalog-exact',
      'name': 'Test channel',
      'sourceId': 'reviewed-source',
      'originalChannelId': 'original-exact',
      'countryCode': 'XX',
      'catalogIdentityHash': catalogEpgIdentityHash({
        'id': 'catalog-exact',
        'name': 'Test channel',
        'countryCode': 'XX',
      }),
      'confidence': 1.0,
    },
  ],
  'programmes': [
    for (var i = 0; i < 3; i++)
      {
        'channelId': 'catalog-exact',
        'sourceId': 'reviewed-source',
        'originalChannelId': 'original-exact',
        'title': '$label $i',
        'startUtc': _epoch - 1800 + i * 3600,
        'stopUtc': _epoch + 1800 + i * 3600,
        'provenance': <String, dynamic>{'fixture': true},
      },
  ],
};

class _Api extends BobTvApiClient {
  Map<String, dynamic>? payload = _payload('first');
  int checks = 0, downloads = 0;
  Object? error;
  bool corrupt = false;
  Completer<void>? gate;
  List<int> get bytes => gzip.encode(utf8.encode(jsonEncode(payload)));
  ServerEpgManifest? get manifest {
    if (payload == null) return null;
    final programmes = payload!['programmes'] as List;
    final hash = sha256.convert(bytes).toString();
    return ServerEpgManifest.parse(<String, dynamic>{
      'schemaVersion': 1,
      'version': payload!['version'],
      'sha256': hash,
      'snapshotUrl': '/api/v1/epg/snapshots/$hash.json.gz',
      'compressedBytes': bytes.length,
      'channelCount': (payload!['channels'] as List).length,
      'programmeCount': programmes.length,
      'generatedAt': _at.toIso8601String(),
      'coverageStartUtc': programmes
          .map((p) => p['startUtc'] as int)
          .reduce((a, b) => a < b ? a : b),
      'coverageEndUtc': programmes
          .map((p) => p['stopUtc'] as int)
          .reduce((a, b) => a > b ? a : b),
    });
  }

  @override
  Future<ServerEpgManifest?> fetchEpgManifest() async {
    checks++;
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    return manifest;
  }

  @override
  Future<List<int>> downloadEpgSnapshot(ServerEpgManifest manifest) async {
    downloads++;
    return corrupt ? [1, 2, 3] : bytes;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late _Api api;
  late ServerEpgSyncService service;
  late DateTime clock;
  int decodes = 0;
  setUp(() {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    api = _Api();
    clock = _at;
    decodes = 0;
    service = ServerEpgSyncService(
      database: database,
      api: api,
      now: () => clock,
      decode: (message) {
        decodes++;
        return decodeServerEpg(message);
      },
    );
  });
  tearDown(() async {
    service.dispose();
    api.close();
    await database.close();
  });
  Future<List<String>> titles() async =>
      (await database.select(database.epgProgrammes).get())
          .map((p) => p.title)
          .toList();
  Future<String?> installed() async =>
      (await database
              .customSelect('SELECT manifest FROM server_epg_receipt')
              .getSingleOrNull())
          ?.read<String>('manifest');

  test(
    'government data credits import and hot update without false sharealike',
    () async {
      Map<String, dynamic> government(String version) {
        final value = _payload(version);
        value['dataAttributions'] = [
          {
            ..._credit(label: 'Synthetic government provider 2026'),
            'attributionUrl': 'https://data.gov.tw/dataset/121175',
            'licenseUrl': 'https://data.gov.tw/license',
            'shareAlikeRequired': false,
          },
        ];
        for (final programme in value['programmes'] as List) {
          programme['provenance']['dataLicense'] =
              'Open Government Data License 1.0';
        }
        return value;
      }

      api.payload = government('government-first');
      expect(await service.check(), isTrue);
      expect(
        service.state.value.attributions.single.dataLicense,
        'Open Government Data License 1.0',
      );
      expect(
        service.state.value.attributions.single.json['shareAlikeRequired'],
        false,
      );
      api.payload = government('government-second');
      expect(await service.check(forceVersionCheck: true), isTrue);
      expect(await titles(), [
        'government-second 0',
        'government-second 1',
        'government-second 2',
      ]);
      api.payload = government('government-invalid')
        ..remove('dataAttributions');
      expect(await service.check(forceVersionCheck: true), isFalse);
      expect(await titles(), [
        'government-second 0',
        'government-second 1',
        'government-second 2',
      ]);
      expect(
        service.state.value.attributions.single.licenseUrl,
        'https://data.gov.tw/license',
      );
    },
  );

  test(
    'credits persist, survive offline restart and unchanged checks',
    () async {
      api.payload = _licensed('first');
      expect(await service.check(), isTrue);
      expect(service.state.value.attributions.single.sourceLabel, 'TVmaze');
      final rows = await database
          .customSelect('SELECT * FROM server_epg_attributions')
          .get();
      expect(rows, hasLength(1));
      service.dispose();
      service = ServerEpgSyncService(
        database: database,
        api: api,
        now: () => clock,
        decode: decodeServerEpg,
      );
      api.error = const SocketException('offline');
      expect(await service.check(), isFalse);
      expect(service.state.value.attributions.single.sourceLabel, 'TVmaze');
      api.error = null;
      clock = clock.add(const Duration(minutes: 5));
      expect(await service.check(), isFalse);
      expect(api.downloads, 1);
      expect(service.state.value.phase, 'unchanged');
    },
  );

  test(
    'existing database gains the credit cache without losing private data',
    () async {
      service.dispose();
      await database.close();
      final directory = await Directory.systemTemp.createTemp(
        'bobtv-epg-credits-',
      );
      final file = File('${directory.path}/cache.sqlite');
      var cached = db.AppDatabase.forTesting(NativeDatabase(file));
      try {
        await cached.upsertEpgSource(
          db.EpgSourcesCompanion.insert(
            id: 'private',
            name: 'Private guide',
            url: 'https://example.org/guide.xml',
          ),
        );
        await cached.customStatement('DROP TABLE server_epg_attributions');
        await cached.close();
        cached = db.AppDatabase.forTesting(NativeDatabase(file));
        expect((await cached.getAllEpgSources()).single.id, 'private');
        expect(
          await cached
              .customSelect('SELECT * FROM server_epg_attributions')
              .get(),
          isEmpty,
        );
      } finally {
        await cached.close();
        database = db.AppDatabase.forTesting(NativeDatabase.memory());
        await directory.delete(recursive: true);
      }
    },
  );

  test('credit transaction failure retains old credits and guide', () async {
    api.payload = _licensed('first');
    await service.check();
    final before = await installed();
    await database.customStatement(
      "CREATE TRIGGER reject_credit BEFORE INSERT ON server_epg_attributions WHEN NEW.metadata LIKE '%replacement%' BEGIN SELECT RAISE(ABORT,'fixture'); END",
    );
    api.payload = _licensed('second', label: 'replacement');
    expect(await service.check(forceVersionCheck: true), isFalse);
    expect(await installed(), before);
    expect(await titles(), ['first 0', 'first 1', 'first 2']);
    expect(service.state.value.attributions.single.sourceLabel, 'TVmaze');
    final row = await database
        .customSelect('SELECT metadata FROM server_epg_attributions')
        .getSingle();
    expect(jsonDecode(row.read<String>('metadata'))['sourceLabel'], 'TVmaze');
  });

  test(
    'a newer version replaces credits and unlicensed version removes them',
    () async {
      api.payload = _licensed('first');
      await service.check();
      api.payload = _licensed('second', label: 'Updated provider');
      expect(await service.check(forceVersionCheck: true), isTrue);
      expect(
        service.state.value.attributions.single.sourceLabel,
        'Updated provider',
      );
      api.payload = _payload('third');
      expect(await service.check(forceVersionCheck: true), isTrue);
      expect(service.state.value.attributions, isEmpty);
      expect(
        await database
            .customSelect('SELECT * FROM server_epg_attributions')
            .get(),
        isEmpty,
      );
    },
  );

  for (final kind in [
    'missing',
    'duplicate',
    'unrelated',
    'unsafe-url',
    'wrong-license',
    'blank-notice',
    'mixed-license',
    'invalid-list',
    'no-share-alike',
  ]) {
    test('rejects $kind attribution and keeps the last valid guide', () async {
      api.payload = _licensed('first');
      await service.check();
      final before = await installed();
      final invalid = _licensed('second');
      final credits = invalid['dataAttributions'] as List;
      switch (kind) {
        case 'missing':
          invalid.remove('dataAttributions');
        case 'duplicate':
          credits.add(_credit());
        case 'unrelated':
          credits[0]['sourceId'] = 'unrelated';
        case 'unsafe-url':
          credits[0]['attributionUrl'] = 'http://127.0.0.1/';
        case 'wrong-license':
          credits[0]['licenseUrl'] = 'https://example.org/';
        case 'blank-notice':
          credits[0]['modificationNotice'] = ' ';
        case 'mixed-license':
          invalid['programmes'][0]['provenance']['dataLicense'] = 'other';
        case 'invalid-list':
          invalid['dataAttributions'] = {};
        case 'no-share-alike':
          credits[0]['shareAlikeRequired'] = false;
      }
      api.payload = invalid;
      expect(await service.check(forceVersionCheck: true), isFalse);
      expect(service.state.value.error, 'invalid_epg_data');
      expect(await installed(), before);
      expect(await titles(), ['first 0', 'first 1', 'first 2']);
      expect(service.state.value.attributions.single.sourceLabel, 'TVmaze');
    });
  }

  test(
    'two versions inside four hours atomically replace only managed data',
    () async {
      await database.upsertEpgSource(
        db.EpgSourcesCompanion.insert(
          id: 'private',
          name: 'Private',
          url: 'https://example.org/private.xml',
        ),
      );
      await database.insertEpgProgrammes([
        db.EpgProgrammesCompanion.insert(
          epgChannelId: 'private_exact',
          sourceId: 'private',
          title: 'Private',
          start: _at,
          stop: _at.add(const Duration(hours: 1)),
        ),
      ]);
      await database.upsertProvider(
        db.ProvidersCompanion.insert(
          id: 'private-provider',
          name: 'Private provider',
          type: 'm3u',
        ),
      );
      await database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'private-channel',
          providerId: 'private-provider',
          name: 'Private',
          streamUrl: 'https://example.org/live.m3u8',
        ),
      ]);
      await database.upsertMapping(
        db.EpgMappingsCompanion.insert(
          channelId: 'private-channel',
          providerId: 'private-provider',
          epgChannelId: 'exact',
          epgSourceId: 'private',
          locked: const Value(true),
          source: const Value('manual'),
        ),
      );
      expect(await service.check(), isTrue);
      final firstReceipt = await installed();
      api.payload = _payload('second');
      clock = clock.add(const Duration(minutes: 5));
      expect(await service.check(), isTrue);
      expect(await titles(), ['Private', 'second 0', 'second 1', 'second 2']);
      expect(await installed(), isNot(firstReceipt));
      expect(service.state.value.phase, 'updated');
      expect(service.state.value.expiredAt(clock), isFalse);
      final manual = (await database.getAllMappings()).single;
      expect(manual.epgSourceId, 'private');
      expect(manual.locked, isTrue);
      expect(
        (await database
            .customSelect('SELECT * FROM server_epg_identities')
            .get()),
        hasLength(1),
      );
    },
  );

  test('unchanged versions do not download or parse again', () async {
    await service.check();
    await service.check(forceVersionCheck: true);
    expect(api.checks, 2);
    expect(api.downloads, 1);
    expect(decodes, 1);
    expect(service.state.value.phase, 'unchanged');
  });

  test(
    'production background-isolate decoder imports a complete version',
    () async {
      service.dispose();
      service = ServerEpgSyncService(
        database: database,
        api: api,
        now: () => _at,
      );
      expect(await service.check(), isTrue);
      expect(await titles(), ['first 0', 'first 1', 'first 2']);
      expect(service.state.value.phase, 'updated');
    },
  );

  test(
    'offline failure retains version and cache and exposes expiry',
    () async {
      await service.check();
      final before = await installed();
      clock = clock.add(const Duration(hours: 4));
      api.error = const SocketException('offline');
      expect(await service.check(), isFalse);
      expect(await installed(), before);
      expect(await titles(), ['first 0', 'first 1', 'first 2']);
      expect(service.state.value.phase, 'failed');
      expect(service.state.value.expiredAt(clock), isTrue);
    },
  );

  test(
    'checksum failure retains previous transaction and schedules retry',
    () async {
      await service.check();
      final before = await installed();
      api.payload = _payload('second');
      api.corrupt = true;
      expect(await service.check(forceVersionCheck: true), isFalse);
      expect(await installed(), before);
      expect(await titles(), ['first 0', 'first 1', 'first 2']);
      expect(service.state.value.error, 'invalid_epg_data');
    },
  );

  test(
    'failed database commit rolls back version identities and programmes',
    () async {
      await service.check();
      final before = await installed();
      await database.customStatement(
        "CREATE TRIGGER reject_second BEFORE INSERT ON epg_programmes WHEN NEW.title='second 1' BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      api.payload = _payload('second');
      expect(await service.check(forceVersionCheck: true), isFalse);
      expect(await installed(), before);
      expect(await titles(), ['first 0', 'first 1', 'first 2']);
      expect(
        (await database.getEpgChannelsForSource(
          serverEpgSourceId,
        )).single.displayName,
        'Test channel',
      );
    },
  );

  test('concurrent triggers share one request and one import', () async {
    api.gate = Completer<void>();
    final a = service.check();
    final b = service.check(forceVersionCheck: true);
    expect(identical(a, b), isTrue);
    api.gate!.complete();
    expect(await a, isTrue);
    expect(await b, isTrue);
    expect(api.checks, 1);
    expect(api.downloads, 1);
  });

  test(
    'upstream Retry-After is respected by foreground and reconnect triggers',
    () async {
      api.error = const BobTvApiException(
        'epg_manifest_status',
        statusCode: 429,
        retryAfter: Duration(minutes: 10),
      );
      expect(await service.check(), isFalse);
      expect(
        service.state.value.nextCheckAt,
        _at.add(const Duration(minutes: 10)),
      );
      clock = _at.add(const Duration(minutes: 5));
      service.onAppResumed();
      service.onNetworkRestored();
      await service.check(forceVersionCheck: true);
      expect(api.checks, 1);
      api.error = null;
      clock = _at.add(const Duration(minutes: 10));
      expect(await service.check(), isTrue);
      expect(api.checks, 2);
    },
  );

  for (final error in [
    const SocketException('fixture offline'),
    TimeoutException('fixture connection timeout'),
  ]) {
    test(
      'reconnect immediately clears only ${error.runtimeType} backoff',
      () async {
        api.error = error;
        expect(await service.check(), isFalse);
        expect(service.state.value.nextCheckAt!.isAfter(clock), isTrue);
        api.error = null;
        service.onNetworkRestored();
        expect(await service.check(), isTrue);
        expect(api.checks, 2);
        expect(api.downloads, 1);
      },
    );
  }

  test('reconnect does not bypass invalid-data backoff', () async {
    api.corrupt = true;
    expect(await service.check(), isFalse);
    api.corrupt = false;
    service.onNetworkRestored();
    expect(await service.check(forceVersionCheck: true), isFalse);
    expect(api.checks, 1);
    expect(api.downloads, 1);
  });

  test(
    'reconnect during an in-flight failed request schedules one catch-up',
    () async {
      api.error = const SocketException('fixture offline');
      api.gate = Completer<void>();
      final pending = service.check();
      service.onNetworkRestored();
      api.gate!.complete();
      expect(await pending, isFalse);
      await service.check(forceVersionCheck: true);
      expect(api.checks, 2);
      expect(api.downloads, 0);
    },
  );

  test(
    'foreground check can receive a new version before normal polling',
    () async {
      await service.check();
      api.payload = _payload('second');
      service.onAppResumed();
      expect(await service.check(), isTrue);
      expect(await titles(), ['second 0', 'second 1', 'second 2']);
    },
  );

  test('empty server manifest does not erase last valid cache', () async {
    await service.check();
    final before = await installed();
    api.payload = null;
    expect(await service.check(forceVersionCheck: true), isFalse);
    expect(await installed(), before);
    expect(service.state.value.phase, 'unpublished');
  });

  test(
    'periodic receiver sees two versions after startup without another start',
    () async {
      service.dispose();
      service = ServerEpgSyncService(
        database: database,
        api: api,
        now: () => DateTime.now().toUtc(),
        pollInterval: const Duration(milliseconds: 30),
        decode: decodeServerEpg,
      );
      // Keep the scheduling clock real, offset the fixture intervals to real now.
      final delta =
          DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 - _epoch;
      Map<String, dynamic> liveFixture(String label) {
        final data = _payload(label);
        for (final p in data['programmes'] as List) {
          p['startUtc'] = (p['startUtc'] as int) + delta;
          p['stopUtc'] = (p['stopUtc'] as int) + delta;
        }
        return data;
      }

      api.payload = liveFixture('first');
      final complete = Completer<void>();
      service.state.addListener(() {
        if (service.state.value.phase == 'updated') {
          if (api.downloads == 1) api.payload = liveFixture('second');
          if (api.downloads == 2 && !complete.isCompleted) complete.complete();
        }
      });
      service.start();
      await complete.future.timeout(const Duration(seconds: 5));
      expect(api.downloads, 2);
      expect(await titles(), ['second 0', 'second 1', 'second 2']);
    },
  );

  for (final kind in [
    'unknown-channel',
    'wrong-source',
    'overlap',
    'expired',
    'no-future',
  ]) {
    test('rejects $kind payload without changing valid cache', () async {
      await service.check();
      final before = await installed();
      final invalid = _payload('bad');
      final programmes = invalid['programmes'] as List;
      switch (kind) {
        case 'unknown-channel':
          programmes[0]['channelId'] = 'other';
        case 'wrong-source':
          programmes[0]['sourceId'] = 'other';
        case 'overlap':
          programmes[1]['startUtc'] -= 1;
        case 'expired':
          for (final p in programmes) {
            p['startUtc'] -= 86400;
            p['stopUtc'] -= 86400;
          }
        case 'no-future':
          programmes.removeWhere((p) => (p['startUtc'] as int) > _epoch);
      }
      api.payload = invalid;
      expect(await service.check(forceVersionCheck: true), isFalse);
      expect(await installed(), before);
      expect(await titles(), ['first 0', 'first 1', 'first 2']);
    });
  }

  test(
    'current gap imports real future rows without a fake now entry',
    () async {
      expect(await service.check(), isTrue);
      final gap = _payload('real-future-gap');
      (gap['programmes'] as List).removeWhere(
        (p) => (p['startUtc'] as int) <= _epoch,
      );
      api.payload = gap;
      expect(await service.check(forceVersionCheck: true), isTrue);
      expect(await titles(), ['real-future-gap 1', 'real-future-gap 2']);
      final channel =
          (await database.select(database.epgChannels).get()).single;
      final upcoming = await database.getUpcomingProgrammes(
        epgChannelId: channel.id,
        at: clock,
        limit: 3,
      );
      expect(upcoming, hasLength(2));
      expect(upcoming.every((p) => p.start.isAfter(clock)), isTrue);
      final current = (await database.select(database.epgProgrammes).get())
          .where(
            (p) =>
                p.epgChannelId == channel.id &&
                !p.start.isAfter(clock) &&
                p.stop.isAfter(clock),
          );
      expect(current, isEmpty);
      expect(await service.check(forceVersionCheck: true), isFalse);
      expect(api.downloads, 2);
      api.error = const SocketException('offline gap fixture');
      expect(await service.check(forceVersionCheck: true), isFalse);
      expect(await titles(), ['real-future-gap 1', 'real-future-gap 2']);
    },
  );

  test('manifest cannot redirect a snapshot outside fixed BobTV path', () {
    final value = Map<String, dynamic>.from(api.manifest!.json);
    value['snapshotUrl'] = 'https://example.org/file.json.gz';
    expect(() => ServerEpgManifest.parse(value), throwsFormatException);
  });

  test(
    'disabled managed source is respected without a network request',
    () async {
      await service.check();
      await (database.update(database.epgSources)
            ..where((row) => row.id.equals(serverEpgSourceId)))
          .write(const db.EpgSourcesCompanion(enabled: Value(false)));
      api.payload = _payload('second');
      expect(await service.check(forceVersionCheck: true), isFalse);
      expect(api.checks, 1);
      expect(service.state.value.phase, 'disabled');
      expect(await titles(), ['first 0', 'first 1', 'first 2']);
    },
  );
}
