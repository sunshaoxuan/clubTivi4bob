import 'dart:async';
import 'package:clubtivi/data/services/channel_route_recovery_service.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const oldUrl = 'https://media.example.org/old.m3u8';
const newUrl = 'https://media.example.org/new.m3u8';
final job = 'a' * 64;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'same identity request polls only BobTV then retries an unseen route once',
    () async {
      var submitted = 0, synced = 0, delivered = 0;
      var routes = [const RecoveryRoute('old', oldUrl)];
      final service = ChannelRouteRecoveryService(
        automaticPolling: false,
        submit: (id, url) async {
          expect(id, 'MY-AEC');
          expect(url, oldUrl);
          submitted++;
          return {'id': job, 'state': 'queued'};
        },
        result: (_) async => {'state': 'queued', 'nextRetryAt': 9999999999},
        syncCatalog: () async {
          synced++;
        },
        readRoutes: (_) async => routes,
        onAvailable: (id, added) async {
          expect(id, 'MY-AEC');
          expect(added.single.url, newUrl);
          delivered++;
        },
      );
      addTearDown(service.dispose);
      await service.request('MY-AEC', oldUrl);
      await service.request('MY-AEC', oldUrl);
      expect(submitted, 1);
      routes = [...routes, const RecoveryRoute('new', newUrl)];
      await service.poll();
      await service.poll();
      expect(delivered, 1);
      expect(synced, 2);
    },
  );

  test(
    'new playback intent and dispose suppress a delayed recovery callback',
    () async {
      var routes = [const RecoveryRoute('old', oldUrl)];
      final sync = Completer<void>();
      var wait = false, delivered = 0;
      final service = ChannelRouteRecoveryService(
        automaticPolling: false,
        submit: (_, _) async => {'id': job, 'state': 'queued'},
        result: (_) async => {'state': 'queued'},
        syncCatalog: () async {
          if (wait) await sync.future;
        },
        readRoutes: (_) async => routes,
        onAvailable: (_, _) async {
          delivered++;
        },
      );
      await service.request('MY-AEC', oldUrl);
      routes = [...routes, const RecoveryRoute('new', newUrl)];
      wait = true;
      final polling = service.poll();
      service.cancel();
      sync.complete();
      await polling;
      expect(delivered, 0);
      service.dispose();
      await service.request('MY-AEC', oldUrl);
      expect(delivered, 0);
    },
  );

  test(
    'server retry floor suppresses result checks while catalog remains observable',
    () async {
      var now = DateTime.utc(2030);
      var checks = 0, syncs = 0;
      final service = ChannelRouteRecoveryService(
        automaticPolling: false,
        now: () => now,
        submit: (_, _) async => {
          'id': job,
          'state': 'queued',
          'nextRetryAt':
              now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
        },
        result: (_) async {
          checks++;
          return {'state': 'queued'};
        },
        syncCatalog: () async {
          syncs++;
        },
        readRoutes: (_) async => [const RecoveryRoute('old', oldUrl)],
        onAvailable: (_, _) async {},
      );
      addTearDown(service.dispose);
      await service.request('MY-AEC', oldUrl);
      await service.poll();
      expect(checks, 0);
      expect(syncs, 2);
      now = now.add(const Duration(hours: 1));
      await service.poll();
      expect(checks, 1);
    },
  );

  test(
    'offline polling keeps the intent and resumes without repeated submission',
    () async {
      var offline = true, delivered = 0, submissions = 0;
      var routes = [const RecoveryRoute('old', oldUrl)];
      final service = ChannelRouteRecoveryService(
        automaticPolling: false,
        submit: (_, _) async {
          submissions++;
          return {'id': job, 'state': 'queued'};
        },
        result: (_) async => {'state': 'queued'},
        syncCatalog: () async {
          if (offline) throw StateError('offline');
        },
        readRoutes: (_) async => routes,
        onAvailable: (_, _) async {
          delivered++;
        },
      );
      addTearDown(service.dispose);
      await service.request('MY-AEC', oldUrl);
      offline = false;
      routes = [...routes, const RecoveryRoute('new', newUrl)];
      await service.poll();
      expect(delivered, 1);
      expect(submissions, 1);
    },
  );

  test(
    'done receipt cannot acknowledge a catalog that is still cached or offline',
    () async {
      var routes = [const RecoveryRoute('old', oldUrl)];
      var delivered = 0;
      final service = ChannelRouteRecoveryService(
        automaticPolling: false,
        submit: (_, _) async => {'id': job, 'state': 'done'},
        result: (_) async => {
          'state': 'done',
          'items': [
            {'added': 1},
          ],
        },
        syncCatalog: () async {},
        readRoutes: (_) async => routes,
        onAvailable: (_, _) async {
          delivered++;
        },
      );
      addTearDown(service.dispose);
      await service.request('MY-AEC', oldUrl);
      expect(delivered, 0);
      routes = [...routes, const RecoveryRoute('new', newUrl)];
      await service.poll();
      expect(delivered, 1);
    },
  );

  test(
    'exact public route lookup excludes name collisions, private and retired rows',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      for (final provider in ['bobtv-channel-catalog', 'private']) {
        await database.upsertProvider(
          db.ProvidersCompanion.insert(
            id: provider,
            name: provider,
            type: 'm3u',
          ),
        );
      }
      for (final (id, provider, catalogId) in [
        ('old', 'bobtv-channel-catalog', 'MY-AEC'),
        ('new', 'bobtv-channel-catalog', 'MY-AEC'),
        ('same-name', 'bobtv-channel-catalog', 'US-AEC'),
        ('private', 'private', 'MY-AEC'),
      ]) {
        await database.upsertChannels([
          db.ChannelsCompanion.insert(
            id: id,
            providerId: provider,
            name: 'AEC',
            streamUrl: 'https://media.example.org/$id.m3u8',
          ),
        ]);
        await database.customStatement(
          'INSERT INTO catalog_epg_routes VALUES(?,?,?,?,?,?)',
          [id, catalogId, 'hash', 'AEC', null, null],
        );
      }
      await database.blockAndDeleteStreamUrl(
        oldUrl,
        reason: 'user_reported_wrong_content',
      );
      expect(
        (await database.publicRoutesForCatalogChannel(
          'MY-AEC',
        )).map((c) => c.id),
        ['new'],
      );
    },
  );
}
