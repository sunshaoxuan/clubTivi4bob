import 'dart:async';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/channel_route_sync_service.dart';
import 'package:clubtivi/data/services/website_channel_catalog_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clubtivi/data/services/retired_route_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  const first = 'https://media.example.org/first.m3u8';
  const second = 'https://media.example.org/second.m3u8';
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await database.upsertProvider(
      db.ProvidersCompanion.insert(
        id: WebsiteChannelCatalogService.providerId,
        name: 'shared',
        type: 'catalog',
      ),
    );
    await database.withoutSharedReporting(
      () => database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'one',
          providerId: WebsiteChannelCatalogService.providerId,
          name: 'CCTV-6',
          streamUrl: first,
        ),
        db.ChannelsCompanion.insert(
          id: 'two',
          providerId: WebsiteChannelCatalogService.providerId,
          name: 'CCTV-6',
          streamUrl: second,
        ),
      ]),
    );
  });
  tearDown(() => database.close());

  test(
    'native entry cannot open a remotely retired route before periodic sync',
    () async {
      final sync = ChannelRouteSyncService(
        database: database,
        fetch: (_) async => const BobTvRouteState(retiredUrls: {first}),
      );
      final guard = RetiredRouteGuard(
        read: database.getBlockedStreamUrls,
        updates: const Stream<Set<String>>.empty(),
        beforeOpen: sync.beforeOpen,
      );
      addTearDown(() async {
        sync.dispose();
        await guard.dispose();
      });
      var opens = 0;
      await expectLater(
        guard.open(first, () async {
          opens++;
        }, stop: () async {}),
        throwsA(isA<RetiredRouteException>()),
      );
      expect(opens, 0);
    },
  );

  test(
    'selection saves remote retirement before allowing any decoder open',
    () async {
      var reads = 0;
      final sync = ChannelRouteSyncService(
        database: database,
        fetch: (urls) async {
          reads++;
          return const BobTvRouteState(retiredUrls: {first});
        },
      );
      addTearDown(sync.dispose);
      await sync.priority([first, second]);
      expect(await database.getBlockedStreamUrls(), {first});
      expect(
        (await database.getChannelsByStreamUrls([
          first,
          second,
        ])).map((c) => c.streamUrl),
        [second],
      );
      await sync.beforeOpen(first);
      expect(reads, 1);
      expect(await database.pendingSharedEvents(), isEmpty);
    },
  );

  test(
    'a later empty remote answer never restores a permanent retirement',
    () async {
      var retired = <String>{first};
      final sync = ChannelRouteSyncService(
        database: database,
        fetch: (_) async => BobTvRouteState(retiredUrls: retired),
      );
      addTearDown(sync.dispose);
      await sync.priority([first]);
      retired = {};
      await sync.priority([first]);
      expect(await database.isStreamUrlBlocked(first), isTrue);
    },
  );

  test('foreground request bypasses an in-flight category page', () async {
    final started = Completer<void>();
    final release = Completer<BobTvRouteState>();
    final calls = <List<String>>[];
    final sync = ChannelRouteSyncService(
      database: database,
      fetch: (urls) async {
        calls.add(urls);
        if (calls.length == 1) {
          started.complete();
          return release.future;
        }
        return const BobTvRouteState(retiredUrls: {});
      },
    );
    sync.queueCategory([
      for (var i = 0; i < 250; i++) 'https://media.example.org/$i.m3u8',
    ]);
    await started.future;
    await sync.priority([second]);
    expect(calls[0].length, 100);
    expect(calls[1], [second]);
    sync.dispose();
    release.complete(const BobTvRouteState(retiredUrls: {}));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls.length, 2);
  });

  test(
    'simultaneous clicks coalesce but a later click performs a fresh request',
    () async {
      final finish = Completer<BobTvRouteState>();
      var calls = 0;
      final sync = ChannelRouteSyncService(
        database: database,
        fetch: (_) async {
          calls++;
          return calls == 1
              ? finish.future
              : const BobTvRouteState(retiredUrls: {});
        },
      );
      addTearDown(sync.dispose);
      final a = sync.priority([first]);
      final b = sync.priority([first]);
      finish.complete(const BobTvRouteState(retiredUrls: {}));
      await Future.wait([a, b]);
      expect(calls, 1);
      await sync.priority([first]);
      expect(calls, 2);
    },
  );

  test(
    'offline foreground sync reports failure and preserves local exclusions',
    () async {
      await database.withoutSharedReporting(
        () => database.blockAndDeleteStreamUrl(
          first,
          reason: 'shared_catalog_retired',
        ),
      );
      final sync = ChannelRouteSyncService(
        database: database,
        fetch: (_) async {
          throw StateError('offline');
        },
      );
      addTearDown(sync.dispose);
      await expectLater(sync.priority([second]), throwsStateError);
      expect(await database.isStreamUrlBlocked(first), isTrue);
    },
  );
}
