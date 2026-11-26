import 'dart:async';
import 'dart:convert';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/features/account/account_service.dart';
import 'package:clubtivi/features/account/regional_catalog_client.dart';
import 'package:clubtivi/features/account/regional_catalog_service.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> bootstrap() => {
  'format': 'bobtv-sync-bootstrap',
  'schemaVersion': 1,
  'algorithm': 'Ed25519',
  'apiBase': 'https://bobtv.briconbric.com/api/v1/regional-catalog',
  'publicKey': base64UrlEncode(List.filled(32, 1)).replaceAll('=', ''),
  'keyId': sha256.convert(List.filled(32, 1)).toString(),
};

class TestAccount extends AccountService {
  bool signedIn = true;
  TestAccount() {
    user = {'id': 'a' * 32};
  }
  @override
  bool get loggedIn => signedIn;
  @override
  Future<void> initialize() async {}
  void login(String id) {
    signedIn = true;
    user = {'id': id};
    notifyListeners();
  }

  Future<void> logout() async {
    signedIn = false;
    user = null;
    notifyListeners();
  }

  @override
  Future<Map<String, dynamic>> regionalCatalogRequest(
    String operation, {
    Map<String, dynamic>? body,
  }) async => bootstrap();
}

class TestCatalog extends RegionalCatalogClient {
  TestCatalog(super.account);
  bool fail = false;
  int revocations = 0;
  Completer<void>? blocked;
  Completer<void>? started;
  @override
  Future<RegionalCatalogBootstrap> verifyBootstrap(
    Map<String, dynamic> imported,
  ) async =>
      RegionalCatalogBootstrap.parse(imported, Uri.parse(account.origin));
  @override
  Future<void> enroll(RegionalCatalogBootstrap publisher) async {}
  @override
  Future<void> revoke(RegionalCatalogBootstrap publisher) async {
    if (fail) throw StateError('offline');
    revocations++;
  }

  @override
  Future<Map<String, int>> regions(RegionalCatalogBootstrap publisher) async =>
      {'JP': 1, 'HK': 1};
  @override
  Future<Map<String, dynamic>?> syncSnapshot(
    RegionalCatalogBootstrap publisher,
    String region, {
    String? knownRevision,
  }) async {
    if (started?.isCompleted == false) started!.complete();
    await blocked?.future;
    if (fail) throw StateError('offline');
    return {
      'revision': region * 32,
      'catalog': {
        'schemaVersion': 1,
        'version': '2026-11-22T00:00:00Z',
        'categories': [
          {'id': 'world', 'name': '国际', 'parentId': null},
          {
            'id': 'country',
            'name': region == 'JP' ? '日本' : '香港',
            'parentId': 'world',
          },
          {'id': 'tv', 'name': '综合', 'parentId': 'country'},
        ],
        'channels': [
          {
            'id': 'channel-$region',
            'name': 'TV $region',
            'categoryId': 'tv',
            'countryCode': region == 'HK' ? 'CN' : region,
            if (region == 'HK') 'regionCode': 'HK',
            'routes': [
              {
                'id': 'route-$region',
                'url': 'https://media.example.org/$region.m3u8',
              },
            ],
          },
        ],
      },
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late TestAccount account;
  late TestCatalog client;
  late RegionalCatalogService service;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    account = TestAccount();
    client = TestCatalog(account);
    service = RegionalCatalogService(
      database,
      account: account,
      catalogClient: client,
    );
    await service.initialize();
    await service.refresh();
    await service.loadRegions();
  });
  tearDown(() async {
    service.dispose();
    account.dispose();
    await database.close();
  });

  test(
    'legacy upgrade keeps channels and favorites without account migration',
    () async {
      await service.select({'JP'});
      const id = 'bobtv-channel-catalog:route-JP';
      await (database.update(database.channels)..where((c) => c.id.equals(id)))
          .write(const db.ChannelsCompanion(favorite: Value(true)));
      service.dispose();
      account.signedIn = false;
      account.user = null;
      service = RegionalCatalogService(
        database,
        account: account,
        catalogClient: client,
        allowLegacyCatalog: true,
      );
      await service.initialize();
      await service.refresh();
      expect(service.canUseCatalog, isTrue);
      expect(service.hasAccess, isFalse);
      expect((await database.getChannelsByIds({id})).single.favorite, isTrue);
      expect(await database.getChannelsForProvider('bobtv-demo'), isEmpty);
      account.login('b' * 32);
      await service.refresh();
      await account.logout();
      await service.refresh();
      expect(service.canUseCatalog, isTrue);
      expect((await database.getChannelsByIds({id})).single.favorite, isTrue);
    },
  );

  test(
    'device disconnect stops syncing and restores account favorites on resubscription',
    () async {
      await service.select({'JP'});
      const id = 'bobtv-channel-catalog:route-JP';
      await (database.update(database.channels)..where((c) => c.id.equals(id)))
          .write(const db.ChannelsCompanion(favorite: Value(true)));
      client.fail = true;
      await expectLater(service.disconnectDevice(), throwsStateError);
      expect(service.selected, {'JP'});
      client.fail = false;
      await service.disconnectDevice();
      expect(client.revocations, 1);
      expect(service.selected, isEmpty);
      expect(
        await database.getChannelsForProvider('bobtv-channel-catalog'),
        isEmpty,
      );
      await service.refresh();
      expect(service.selected, isEmpty);
      await service.loadRegions();
      await service.select({'JP'});
      expect((await database.getChannelsByIds({id})).single.favorite, isTrue);
    },
  );

  test(
    'selected regions retain exact public IDs and favorites across resubscription',
    () async {
      await service.select({'JP'});
      const id = 'bobtv-channel-catalog:route-JP';
      expect((await database.getChannelsByIds({id})).single.name, 'TV JP');
      await (database.update(database.channels)..where((c) => c.id.equals(id)))
          .write(const db.ChannelsCompanion(favorite: Value(true)));
      await service.select({'HK'});
      expect(await database.getChannelsByIds({id}), isEmpty);
      await service.select({'JP'});
      expect((await database.getChannelsByIds({id})).single.favorite, isTrue);
    },
  );

  test(
    'failed region download preserves the active snapshot and selection',
    () async {
      await service.select({'JP'});
      client.fail = true;
      await expectLater(service.select({'HK'}), throwsStateError);
      expect(service.selected, {'JP'});
      expect(
        (await database.getChannelsForProvider(
          'bobtv-channel-catalog',
        )).single.name,
        'TV JP',
      );
    },
  );

  test(
    'logout clears protected routes and preserves personal imports',
    () async {
      await service.select({'JP'});
      await database.upsertProvider(
        db.ProvidersCompanion.insert(id: 'mine', name: 'Mine', type: 'manual'),
      );
      await database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'mine-route',
          providerId: 'mine',
          name: 'Mine',
          streamUrl: 'https://media.example.org/mine.m3u8',
        ),
      ]);
      account.logout();
      expect(service.hasAccess, isFalse);
      await service.refresh();
      expect(
        await database.getChannelsForProvider('bobtv-channel-catalog'),
        isEmpty,
      );
      expect(await database.getChannelsForProvider('mine'), hasLength(1));
      account.login('b' * 32);
      await service.refresh();
      expect(service.selected, isEmpty);
      expect(
        await database.getChannelsForProvider('bobtv-channel-catalog'),
        isEmpty,
      );
    },
  );

  test(
    'account change rejects an in-flight response before catalog mutation',
    () async {
      await service.select({'JP'});
      client.blocked = Completer<void>();
      client.started = Completer<void>();
      final pending = service.select({'HK'});
      await client.started!.future;
      account.logout();
      client.blocked!.complete();
      await pending;
      await service.refresh();
      expect(
        await database.getChannelsForProvider('bobtv-channel-catalog'),
        isEmpty,
      );
      expect(service.selected, isEmpty);
    },
  );
}
