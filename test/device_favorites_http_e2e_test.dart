import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/device_favorites_identity.dart';
import 'package:clubtivi/data/services/device_favorites_sync_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final python = Platform.environment['BOBTV_SYNC_E2E_PYTHON'];
  test(
    'real private API: upload, original-device restore, other-device denial and no public favorite data',
    () async {
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = overrides);
      SharedPreferences.setMockInitialValues({});
      final temporary = await Directory.systemTemp.createTemp(
        'bobtv-private-favorites-',
      );
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final server = await Process.start(
        python!,
        ['-m', 'uvicorn', 'app:app', '--host', '127.0.0.1', '--port', '$port'],
        workingDirectory: '${Directory.current.path}/website',
        environment: {'BOBTV_DATA_DIR': temporary.path},
      );
      final messages = StringBuffer();
      server.stdout.transform(utf8.decoder).listen(messages.write);
      server.stderr.transform(utf8.decoder).listen(messages.write);
      addTearDown(() async {
        server.kill();
        await server.exitCode;
        await temporary.delete(recursive: true);
      });
      final uri = Uri.parse('http://127.0.0.1:$port');
      final owner = DeviceFavoritesCredential(
        fingerprint: 'a' * 64,
        token: 'btvf1_${'1' * 64}',
      );
      final other = DeviceFavoritesCredential(
        fingerprint: 'b' * 64,
        token: 'btvf1_${'2' * 64}',
      );
      final probe = BobTvApiClient(baseUri: uri);
      addTearDown(probe.close);
      var ready = false;
      for (var i = 0; i < 50; i++) {
        try {
          await probe.fetchDeviceFavorites(credential: owner);
          ready = true;
          break;
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        ready,
        true,
        reason: 'Private API fixture failed to start: $messages',
      );
      final databases = <db.AppDatabase>[];
      final services = <DeviceFavoritesSyncService>[];
      addTearDown(() async {
        for (final service in services) {
          service.dispose();
        }
        for (final database in databases) {
          await database.close();
        }
      });
      Future<db.AppDatabase> database(String id) async {
        final value = db.AppDatabase.forTesting(NativeDatabase.memory());
        databases.add(value);
        await value.upsertProvider(
          db.ProvidersCompanion.insert(
            id: 'bobtv-channel-catalog',
            name: 'Website',
            type: 'm3u',
          ),
        );
        await value.withoutSharedReporting(
          () => value.upsertChannels([
            db.ChannelsCompanion.insert(
              id: id,
              providerId: 'bobtv-channel-catalog',
              name: 'Own TV',
              streamUrl: 'https://stream.example/favorites.m3u8',
            ),
          ]),
        );
        return value;
      }

      DeviceFavoritesSyncService sync(
        db.AppDatabase data,
        DeviceFavoritesCredential credential,
      ) {
        final value = DeviceFavoritesSyncService(
          database: data,
          api: BobTvApiClient(baseUri: uri),
          credentialLoader: () async => credential,
        );
        services.add(value);
        return value;
      }

      final source = await database('original');
      await source.addChannelToDefaultFavorites('original');
      final first = sync(source, owner);
      await first.sync();
      expect(first.state.value.error, false, reason: first.state.value.phase);
      expect(
        (await probe.fetchDeviceFavorites(
          credential: owner,
        ))!.snapshot!.lists.single.name,
        '我的收藏',
      );
      final originalAfterReinstall = await database('catalog-renamed-id');
      await sync(originalAfterReinstall, owner).sync();
      expect(await originalAfterReinstall.getAllFavoritedChannelIds(), {
        'catalog-renamed-id',
      });
      final unrelated = await database('unrelated');
      await sync(unrelated, other).sync();
      expect(await unrelated.getAllFavoriteLists(), isEmpty);
      expect(await unrelated.getAllFavoritedChannelIds(), isEmpty);
      expect(await probe.fetchDeviceFavorites(credential: other), isNull);
      await expectLater(
        probe.fetchDeviceFavorites(
          credential: DeviceFavoritesCredential(
            fingerprint: other.fingerprint,
            token: owner.token,
          ),
        ),
        throwsA(
          isA<BobTvApiException>().having((e) => e.statusCode, 'status', 403),
        ),
      );
      expect(await source.pendingSharedEvents(), isEmpty);
      expect(await originalAfterReinstall.pendingSharedEvents(), isEmpty);
      expect(await unrelated.pendingSharedEvents(), isEmpty);
      expect(
        await File('${temporary.path}/channel-catalog/manifest.json').exists(),
        false,
      );
      expect(
        await File('${temporary.path}/device_favorites.sqlite3').exists(),
        true,
      );
    },
    skip: python == null
        ? 'Set BOBTV_SYNC_E2E_PYTHON for the real private API fixture'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
