import 'dart:convert';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/models/device_favorites_snapshot.dart';
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/device_favorites_identity.dart';
import 'package:clubtivi/data/services/device_favorites_privacy.dart';
import 'package:clubtivi/data/services/device_favorites_store.dart';
import 'package:clubtivi/data/services/device_favorites_sync_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final credentialA = DeviceFavoritesCredential(
  fingerprint: 'a' * 64,
  token: 'btvf1_${'1' * 64}',
);
final credentialB = DeviceFavoritesCredential(
  fingerprint: 'b' * 64,
  token: 'btvf1_${'2' * 64}',
);
const url = 'https://stream.example/live.m3u8?token=private-subscription';

class FavoriteApi extends BobTvApiClient {
  final backups = <String, DeviceFavoritesBackup>{};
  final uploads = <DeviceFavoritesSnapshot>[];
  bool offline = false;
  Future<void> Function()? beforeRead;
  Future<void> Function()? beforeAck;
  @override
  Future<DeviceFavoritesBackup?> fetchDeviceFavorites({
    required DeviceFavoritesCredential credential,
    int? ifRevision,
  }) async {
    if (offline) throw const BobTvApiException('offline', statusCode: 503);
    await beforeRead?.call();
    final value = backups[credential.localOwner];
    return value != null && value.revision == ifRevision
        ? DeviceFavoritesBackup(revision: value.revision, snapshot: null)
        : value;
  }

  @override
  Future<int> saveDeviceFavorites({
    required DeviceFavoritesCredential credential,
    required DeviceFavoritesSnapshot snapshot,
    required int baseRevision,
  }) async {
    if (offline) throw const BobTvApiException('offline', statusCode: 503);
    final previous = backups[credential.localOwner];
    if (previous != null &&
        jsonEncode(previous.snapshot!.toJson()) ==
            jsonEncode(snapshot.toJson())) {
      return previous.revision;
    }
    if ((previous?.revision ?? 0) != baseRevision) {
      throw const BobTvApiException('conflict', statusCode: 409);
    }
    final revision = baseRevision + 1;
    backups[credential.localOwner] = DeviceFavoritesBackup(
      revision: revision,
      snapshot: snapshot,
    );
    uploads.add(snapshot);
    await beforeAck?.call();
    return revision;
  }
}

Future<void> seed(db.AppDatabase database, {String id = 'original'}) async {
  await database.upsertProvider(
    db.ProvidersCompanion.insert(
      id: 'bobtv-channel-catalog',
      name: 'Website',
      type: 'm3u',
    ),
  );
  await database.withoutSharedReporting(
    () => database.upsertChannels([
      db.ChannelsCompanion.insert(
        id: id,
        providerId: 'bobtv-channel-catalog',
        name: 'Own TV',
        streamUrl: url,
      ),
    ]),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'disabled backup preserves local favorites and never loads credentials',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final api = FavoriteApi();
      var identities = 0;
      final service = DeviceFavoritesSyncService(
        database: database,
        api: api,
        credentialLoader: () async {
          identities++;
          return credentialA;
        },
      );
      addTearDown(() async {
        service.dispose();
        await database.close();
      });
      await seed(database);
      await database.addChannelToDefaultFavorites('original');
      await DeviceFavoritesPrivacy.setEnabled(false);
      await service.sync(force: true);
      expect(identities, 0);
      expect(api.uploads, isEmpty);
      expect(await database.getAllFavoritedChannelIds(), contains('original'));
      await DeviceFavoritesPrivacy.setEnabled(true);
      await service.sync(force: true);
      expect(identities, 1);
      expect(api.uploads.length, 1);
    },
  );

  test(
    'disable during a read prevents restoring and uploading a response',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final api = FavoriteApi();
      api.beforeRead = () => DeviceFavoritesPrivacy.setEnabled(false);
      final service = DeviceFavoritesSyncService(
        database: database,
        api: api,
        credentialLoader: () async => credentialA,
      );
      addTearDown(() async {
        service.dispose();
        await database.close();
      });
      await seed(database);
      await database.addChannelToDefaultFavorites('original');
      await service.sync(force: true);
      expect(api.uploads, isEmpty);
      expect(await database.getAllFavoritedChannelIds(), contains('original'));
    },
  );

  test(
    'secret persists for the original fingerprint and differs on another device',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final first = await DeviceFavoritesIdentity(
        fingerprintLoader: () async => credentialA.fingerprint,
      ).load();
      final original = await DeviceFavoritesIdentity(
        fingerprintLoader: () async => credentialA.fingerprint,
      ).load();
      final other = await DeviceFavoritesIdentity(
        fingerprintLoader: () async => credentialB.fingerprint,
      ).load();
      expect(first!.token, original!.token);
      expect(first.token, isNot(other!.token));
      expect(DeviceFavoritesIdentity.tokenFormat.hasMatch(first.token), true);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  test(
    'corrupted secure credentials do not fall back to a public fingerprint',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'bobtv_private_favorites_v1_${credentialA.fingerprint}': 'invalid',
      });
      await expectLater(
        DeviceFavoritesIdentity(
          fingerprintLoader: () async => credentialA.fingerprint,
        ).load(),
        throwsFormatException,
      );
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  test(
    'private upload contains no URLs and leaves the public outbox empty',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final api = FavoriteApi();
      final service = DeviceFavoritesSyncService(
        database: database,
        api: api,
        credentialLoader: () async => credentialA,
      );
      addTearDown(() async {
        service.dispose();
        await database.close();
      });
      await seed(database);
      await database.addChannelToDefaultFavorites('original');
      await service.sync();
      expect(api.uploads.single.lists.single.routes, [favoriteRouteKey(url)]);
      final body = jsonEncode(api.uploads.single.toJson());
      expect(body, isNot(contains('https://')));
      expect(body, isNot(contains('private-subscription')));
      expect(await database.pendingSharedEvents(), isEmpty);
      await service.sync();
      expect(api.uploads, hasLength(1));
      await database.removeChannelFromList('default', 'original');
      await service.sync();
      expect(api.uploads.last.lists.single.routes, isEmpty);
    },
  );

  test(
    'clean original device restores by route hash after channel IDs change; other device stays empty',
    () async {
      final api = FavoriteApi();
      final original = db.AppDatabase.forTesting(NativeDatabase.memory());
      final first = DeviceFavoritesSyncService(
        database: original,
        api: api,
        credentialLoader: () async => credentialA,
      );
      await seed(original);
      await original.addChannelToDefaultFavorites('original');
      await first.sync();
      // Do not dispose the first service until all shared fixture API use ends.
      final restored = db.AppDatabase.forTesting(NativeDatabase.memory());
      final same = DeviceFavoritesSyncService(
        database: restored,
        api: api,
        credentialLoader: () async => credentialA,
      );
      await seed(restored, id: 'renamed');
      await same.sync();
      expect(await restored.getAllFavoritedChannelIds(), {'renamed'});
      expect(await restored.pendingSharedEvents(), isEmpty);
      final unrelated = db.AppDatabase.forTesting(NativeDatabase.memory());
      final other = DeviceFavoritesSyncService(
        database: unrelated,
        api: api,
        credentialLoader: () async => credentialB,
      );
      await seed(unrelated, id: 'other');
      await other.sync();
      expect(await unrelated.getAllFavoriteLists(), isEmpty);
      expect(await unrelated.getAllFavoritedChannelIds(), isEmpty);
      first.dispose();
      same.dispose();
      other.dispose();
      await original.close();
      await restored.close();
      await unrelated.close();
    },
  );

  test(
    'unloaded references wait for local catalog and cannot restore retired video sources',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final api = FavoriteApi();
      api.backups[credentialA.localOwner] = DeviceFavoritesBackup(
        revision: 1,
        snapshot: DeviceFavoritesSnapshot(
          lists: [
            DeviceFavoriteList(
              id: 'default',
              name: '我的收藏',
              icon: 'star',
              sortOrder: 0,
              routes: [favoriteRouteKey(url)],
            ),
          ],
        ),
      );
      final service = DeviceFavoritesSyncService(
        database: database,
        api: api,
        credentialLoader: () async => credentialA,
      );
      addTearDown(() async {
        service.dispose();
        await database.close();
      });
      await service.sync();
      expect(await database.getAllFavoriteLists(), hasLength(1));
      expect(await database.getAllChannels(), isEmpty);
      await seed(database);
      await database.blockAndDeleteStreamUrl(url, reason: 'manual_pollution');
      await service.sync();
      expect(await database.getAllFavoritedChannelIds(), isEmpty);
    },
  );

  test(
    'local click during restore wins and local edit during upload remains pending',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final api = FavoriteApi();
      final service = DeviceFavoritesSyncService(
        database: database,
        api: api,
        credentialLoader: () async => credentialA,
      );
      addTearDown(() async {
        service.dispose();
        await database.close();
      });
      await seed(database);
      api.backups[credentialA.localOwner] = const DeviceFavoritesBackup(
        revision: 1,
        snapshot: DeviceFavoritesSnapshot(),
      );
      api.beforeRead = () async {
        await database.addChannelToDefaultFavorites('original');
        api.beforeRead = null;
      };
      await service.sync();
      expect(await database.getAllFavoritedChannelIds(), {'original'});
      expect(api.uploads.last.lists.single.routes, [favoriteRouteKey(url)]);
      api.beforeAck = () async {
        await database.renameFavoriteList('default', '新版收藏');
        api.beforeAck = null;
      };
      await database.renameFavoriteList('default', '编辑中');
      await service.sync();
      final pending = await service.store.read();
      expect(pending.revision, greaterThan(pending.acknowledged));
      await service.sync();
      expect(api.uploads.last.lists.single.name, '新版收藏');
    },
  );

  test(
    'offline edits survive retry and malformed remote data is rejected',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final api = FavoriteApi()..offline = true;
      final service = DeviceFavoritesSyncService(
        database: database,
        api: api,
        credentialLoader: () async => credentialA,
      );
      addTearDown(() async {
        service.dispose();
        await database.close();
      });
      await seed(database);
      await database.addChannelToDefaultFavorites('original');
      await service.sync();
      expect(service.state.value.error, true);
      expect(await database.getAllFavoritedChannelIds(), {'original'});
      api.offline = false;
      await service.sync(force: true);
      expect(api.uploads, hasLength(1));
      expect(
        () => DeviceFavoritesSnapshot.parse({
          'lists': [],
          'legacyRoutes': [],
          'url': url,
        }),
        throwsFormatException,
      );
      expect(
        () => DeviceFavoritesSnapshot.parse({
          'lists': [],
          'legacyRoutes': [url],
        }),
        throwsFormatException,
      );
    },
  );
}
