import 'dart:async';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/retired_route_guard.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const retired = 'https://media.example.org/news.m3u8';
const other = 'https://media.example.org/other.m3u8';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('permanent exclusions survive empty and stale updates', () async {
    var saved = <String>{retired};
    final updates = StreamController<Set<String>>.broadcast(sync: true);
    final guard = RetiredRouteGuard(
      read: () async => saved,
      updates: updates.stream,
    );
    addTearDown(() async {
      await guard.dispose();
      await updates.close();
    });
    await guard.refresh();
    expect(guard.allowsCached(retired), isFalse);
    saved = {};
    updates.add({});
    await guard.refresh();
    expect(guard.filter([retired, other]), [other]);
  });

  test(
    'canonical duplicates are blocked without banning the entire host',
    () async {
      final updates = StreamController<Set<String>>.broadcast(sync: true);
      final guard = RetiredRouteGuard(
        read: () async => {retired},
        updates: updates.stream,
      );
      addTearDown(() async {
        await guard.dispose();
        await updates.close();
      });
      await guard.refresh();
      expect(
        guard.allowsCached('https://MEDIA.EXAMPLE.ORG:443/news.m3u8'),
        isFalse,
      );
      expect(guard.allowsCached(other), isTrue);
    },
  );

  test('retired cached candidate never reaches a native open', () async {
    final updates = StreamController<Set<String>>.broadcast(sync: true);
    final guard = RetiredRouteGuard(
      read: () async => {retired},
      updates: updates.stream,
    );
    addTearDown(() async {
      await guard.dispose();
      await updates.close();
    });
    var opened = 0;
    await expectLater(
      guard.open(retired, () async {
        opened++;
      }, stop: () async {}),
      throwsA(isA<RetiredRouteException>()),
    );
    expect(opened, 0);
  });

  test('retirement during connection stops before promotion', () async {
    var saved = <String>{};
    final updates = StreamController<Set<String>>.broadcast(sync: true);
    final guard = RetiredRouteGuard(
      read: () async => saved,
      updates: updates.stream,
    );
    addTearDown(() async {
      await guard.dispose();
      await updates.close();
    });
    final started = Completer<void>();
    final finish = Completer<void>();
    var stops = 0;
    final opening = guard.open(
      retired,
      () async {
        started.complete();
        await finish.future;
      },
      stop: () async {
        stops++;
      },
    );
    final rejected = expectLater(
      opening,
      throwsA(isA<RetiredRouteException>()),
    );
    await started.future;
    saved = {retired};
    updates.add(saved);
    finish.complete();
    await rejected;
    expect(stops, 1);
  });

  test(
    'storage failure fails closed instead of trusting a stale candidate',
    () async {
      final updates = StreamController<Set<String>>.broadcast(sync: true);
      final guard = RetiredRouteGuard(
        read: () async => throw StateError('unavailable'),
        updates: updates.stream,
      );
      addTearDown(() async {
        await guard.dispose();
        await updates.close();
      });
      var opened = false;
      await expectLater(
        guard.open(retired, () async {
          opened = true;
        }, stop: () async {}),
        throwsStateError,
      );
      expect(opened, isFalse);
    },
  );

  test(
    'durable tombstone updates invalidate an already loaded candidate list',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final guard = RetiredRouteGuard(
        read: database.getBlockedStreamUrls,
        updates: database
            .select(database.blockedStreamRoutes)
            .watch()
            .map((rows) => rows.map((r) => r.streamUrl).toSet()),
      );
      addTearDown(() async {
        await guard.dispose();
        await database.close();
      });
      await guard.refresh();
      final cached = [retired, other];
      final change = guard.changes.first;
      await database.blockAndDeleteStreamUrl(
        retired,
        reason: 'shared_catalog_retired',
      );
      expect(await change.timeout(const Duration(seconds: 2)), {retired});
      expect(guard.filter(cached), [other]);
    },
  );

  test(
    'lower weight on one device does not permanently ban another device',
    () async {
      final first = db.AppDatabase.forTesting(NativeDatabase.memory());
      final second = db.AppDatabase.forTesting(NativeDatabase.memory());
      await first.upsertProvider(
        db.ProvidersCompanion.insert(
          id: 'bobtv-channel-catalog',
          name: 'shared',
          type: 'catalog',
        ),
      );
      await first.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'news',
          providerId: 'bobtv-channel-catalog',
          name: 'News',
          streamUrl: retired,
        ),
      ]);
      await first.queueSharedEvent(retired, 'health', {
        'success': 0,
        'failure': 1,
      });
      final guard = RetiredRouteGuard(
        read: second.getBlockedStreamUrls,
        updates: const Stream.empty(),
      );
      addTearDown(() async {
        await guard.dispose();
        await first.close();
        await second.close();
      });
      await guard.requireAllowed(retired);
      expect(await first.getBlockedStreamUrls(), isEmpty);
      expect(guard.allowsCached(retired), isTrue);
    },
  );

  test(
    'blocked play and discovery do not initialize a native decoder',
    () async {
      final guard = RetiredRouteGuard(
        read: () async => {retired},
        updates: const Stream.empty(),
      );
      final service = PlayerService(retirementGuard: guard);
      addTearDown(() async {
        await service.dispose();
        await guard.dispose();
      });
      await service.play(retired);
      expect(service.currentUrl, isNull);
      expect(service.routeSearchProgress.value?.stage, contains('永久淘汰'));
      expect(await service.verifyDiscoveredVideoRoute(retired), isFalse);
      expect(await service.commitPreparedChannel('news'), isFalse);
    },
  );
}
