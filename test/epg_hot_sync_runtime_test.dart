import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/epg_ui_refresh.dart';
import 'package:clubtivi/data/services/server_epg_runtime.dart';
import 'package:clubtivi/data/services/server_epg_sync_service.dart';
import 'package:clubtivi/data/models/server_epg_snapshot.dart';
import 'package:clubtivi/app/server_epg_runtime_host.dart';

class _Service extends ServerEpgSyncService {
  _Service(db.AppDatabase database) : super(database: database);
  int starts = 0, foreground = 0, reconnects = 0;
  @override
  void start() {
    starts++;
  }

  @override
  void onAppResumed() {
    foreground++;
  }

  @override
  void onNetworkRestored() {
    reconnects++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  setUp(() {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => database.close());

  test(
    'runtime starts once and checks foreground and reconnect independently',
    () async {
      final service = _Service(database);
      final network = StreamController<bool>(sync: true);
      var now = DateTime.utc(2026, 10, 16);
      final runtime = ServerEpgRuntime(
        service,
        networkChanges: network.stream,
        observeWindow: false,
        now: () => now,
      );
      runtime.start();
      runtime.start();
      expect(service.starts, 1);
      runtime.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(service.foreground, 0);
      runtime.didChangeAppLifecycleState(AppLifecycleState.resumed);
      runtime.onWindowFocus();
      expect(service.foreground, 1);
      now = now.add(const Duration(seconds: 6));
      runtime.onWindowFocus();
      expect(service.foreground, 2);
      network.add(true);
      network.add(false);
      network.add(true);
      network.add(true);
      expect(service.reconnects, 1);
      runtime.dispose();
      network.add(false);
      network.add(true);
      expect(service.reconnects, 1);
      await network.close();
    },
  );

  test('guide changes coalesce and an in-flight refresh reruns once', () async {
    final changes = StreamController<void>(sync: true);
    final gate = Completer<void>();
    var calls = 0, active = 0, maxActive = 0;
    final refresh = EpgUiRefresh(changes.stream, () async {
      calls++;
      active++;
      if (active > maxActive) maxActive = active;
      if (calls == 1) await gate.future;
      active--;
    }, debounce: const Duration(milliseconds: 2));
    changes.add(null);
    changes.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 12));
    expect(calls, 1);
    changes.add(null);
    changes.add(null);
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 12));
    expect(calls, 2);
    expect(maxActive, 1);
    refresh.dispose();
    changes.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(calls, 2);
    await changes.close();
  });

  test(
    'refresh failure and failing diagnostics cannot block later guide changes',
    () async {
      final changes = StreamController<void>(sync: true);
      var calls = 0;
      final refresh = EpgUiRefresh(
        changes.stream,
        () async {
          calls++;
          if (calls == 1) throw StateError('fixture');
        },
        debounce: Duration.zero,
        onError: (error, stack) => throw StateError('diagnostic fixture'),
      );
      changes.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 8));
      changes.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 8));
      expect(calls, 2);
      refresh.dispose();
      await changes.close();
    },
  );

  test(
    'database invalidation exposes complete commits and keeps cache after rollback',
    () async {
      await database.upsertEpgSource(
        db.EpgSourcesCompanion.insert(
          id: 'guide',
          name: 'Guide',
          url: 'https://example.org/guide.xml',
        ),
      );
      var calls = 0;
      List<String> seen = [];
      final refresh = EpgUiRefresh(database.watchEpgChanges(), () async {
        calls++;
        seen = (await database.select(database.epgProgrammes).get())
            .map((p) => p.title)
            .toList();
      }, debounce: const Duration(milliseconds: 2));
      await Future<void>.delayed(Duration.zero);
      await database.transaction(() async {
        for (final title in ['one', 'two']) {
          await database.insertEpgProgrammes([
            db.EpgProgrammesCompanion.insert(
              epgChannelId: 'guide_exact',
              sourceId: 'guide',
              title: title,
              start: DateTime.now(),
              stop: DateTime.now().add(const Duration(hours: 1)),
            ),
          ]);
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 1);
      expect(seen, ['one', 'two']);
      await expectLater(
        database.transaction(() async {
          await database.deleteEpgProgrammesForSource('guide');
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, 2);
      expect(seen, ['one', 'two']);
      refresh.dispose();
    },
  );

  test(
    'fullscreen lookup receives new mapping and rejects invalidated navigation ID',
    () async {
      await database.upsertProvider(
        db.ProvidersCompanion.insert(id: 'p', name: 'P', type: 'm3u'),
      );
      await database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'c',
          providerId: 'p',
          name: 'Channel',
          streamUrl: 'https://example.org/live.m3u8',
        ),
      ]);
      await database.upsertEpgSource(
        db.EpgSourcesCompanion.insert(
          id: serverEpgSourceId,
          name: 'Guide',
          url: serverEpgManifestUrl,
        ),
      );
      await database.upsertMapping(
        db.EpgMappingsCompanion.insert(
          channelId: 'c',
          providerId: 'p',
          epgChannelId: 'new',
          epgSourceId: serverEpgSourceId,
        ),
      );
      expect(
        await resolveLiveEpgId(
          database,
          channelId: 'c',
          providerId: 'p',
          fallbackId: 'old',
        ),
        '${serverEpgSourceId}_new',
      );
      await database.deleteMapping('c', 'p');
      expect(
        await resolveLiveEpgId(
          database,
          channelId: 'c',
          providerId: 'p',
          fallbackId: '${serverEpgSourceId}_old',
        ),
        isNull,
      );
      expect(
        await resolveLiveEpgId(
          database,
          channelId: 'c',
          providerId: 'p',
          fallbackId: 'private_old',
        ),
        'private_old',
      );
    },
  );

  test('fullscreen lookup respects disabled manual guide source', () async {
    await database.upsertProvider(
      db.ProvidersCompanion.insert(id: 'p', name: 'P', type: 'm3u'),
    );
    await database.upsertChannels([
      db.ChannelsCompanion.insert(
        id: 'c',
        providerId: 'p',
        name: 'Channel',
        streamUrl: 'https://example.org/live.m3u8',
      ),
    ]);
    await database.upsertEpgSource(
      db.EpgSourcesCompanion.insert(
        id: 'private',
        name: 'Private',
        url: 'https://example.org/private.xml',
        enabled: const Value(false),
      ),
    );
    await database.upsertMapping(
      db.EpgMappingsCompanion.insert(
        channelId: 'c',
        providerId: 'p',
        epgChannelId: 'exact',
        epgSourceId: 'private',
        locked: const Value(true),
      ),
    );
    expect(
      await resolveLiveEpgId(
        database,
        channelId: 'c',
        providerId: 'p',
        fallbackId: 'old',
      ),
      isNull,
    );
  });

  testWidgets(
    'cache warning changes without replacing child or resetting scroll',
    (tester) async {
      var now = DateTime.utc(2026, 10, 16);
      final status = ValueNotifier(
        ServerEpgSyncStatus(
          version: 'test',
          coverageEnd: now.add(const Duration(hours: 1)),
        ),
      );
      final scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: [
              ListView(
                controller: scroll,
                children: [
                  for (var i = 0; i < 40; i++)
                    SizedBox(height: 50, child: Text('row $i')),
                ],
              ),
              Align(
                alignment: Alignment.bottomRight,
                child: ServerEpgCacheStatus(
                  state: status,
                  now: () => now,
                  epgChannelId: '${serverEpgSourceId}_test',
                ),
              ),
            ],
          ),
        ),
      );
      scroll.jumpTo(300);
      await tester.pump();
      status.value = ServerEpgSyncStatus(
        phase: 'failed',
        version: 'test',
        coverageEnd: now.add(const Duration(hours: 1)),
      );
      await tester.pump();
      expect(find.textContaining('节目表暂用缓存'), findsOneWidget);
      expect(scroll.offset, 300);
      now = now.add(const Duration(hours: 2));
      await tester.pump(const Duration(minutes: 1));
      expect(find.textContaining('暂无最新节目表'), findsOneWidget);
      expect(scroll.offset, 300);
      await tester.pumpWidget(const SizedBox());
      status.dispose();
      scroll.dispose();
    },
  );

  testWidgets('runtime keeps refreshing without a global expiry overlay', (
    tester,
  ) async {
    final service = _Service(database);
    service.state.value = ServerEpgSyncStatus(
      version: 'old',
      coverageEnd: DateTime.utc(2020),
    );
    final runtime = ServerEpgRuntime(
      service,
      networkChanges: const Stream<bool>.empty(),
      observeWindow: false,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverEpgRuntimeProvider.overrideWith((ref) {
            runtime.start();
            ref.onDispose(runtime.dispose);
            return runtime;
          }),
        ],
        child: const ServerEpgRuntimeHost(
          child: MaterialApp(home: Scaffold(body: Text('playing channel'))),
        ),
      ),
    );
    expect(service.starts, 1);
    expect(find.text('playing channel'), findsOneWidget);
    expect(find.byType(ServerEpgCacheStatus), findsNothing);
    expect(find.textContaining('暂无最新节目表'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    runtime.dispose();
  });

  testWidgets('server expiry is scoped away from private and unmapped guides', (
    tester,
  ) async {
    final state = ValueNotifier(
      ServerEpgSyncStatus(version: 'old', coverageEnd: DateTime.utc(2020)),
    );
    for (final id in [null, 'private_test', '${serverEpgSourceId}_test']) {
      await tester.pumpWidget(
        MaterialApp(
          home: ServerEpgCacheStatus(
            state: state,
            epgChannelId: id,
            fallback: const Text('local guide'),
          ),
        ),
      );
      expect(
        find.textContaining('暂无最新节目表'),
        id == '${serverEpgSourceId}_test' ? findsOneWidget : findsNothing,
      );
    }
    state.value = ServerEpgSyncStatus(
      version: 'new',
      coverageEnd: DateTime.now().add(const Duration(days: 1)),
    );
    await tester.pump();
    expect(find.textContaining('暂无最新节目表'), findsNothing);
    expect(find.text('local guide'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('standalone guide status does not start a network receiver', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: ServerEpgChannelStatus(
            epgChannelId: '${serverEpgSourceId}_test',
            fallback: Text('local guide'),
          ),
        ),
      ),
    );
    expect(find.text('local guide'), findsOneWidget);
    expect(find.byType(ServerEpgCacheStatus), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
