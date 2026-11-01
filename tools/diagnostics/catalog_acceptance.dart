// Native acceptance of the production channel screen. Isolated data and prefs;
// owned audio-free local video, null audio output, no upstream media requests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:clubtivi/app/server_epg_runtime_host.dart';
import 'package:clubtivi/app/theme.dart';
import 'package:clubtivi/core/app_diagnostics.dart';
import 'package:clubtivi/core/platform_info.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/models/server_epg_snapshot.dart';
import 'package:clubtivi/data/services/bobtv_community_service.dart';
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/channel_route_sync_service.dart';
import 'package:clubtivi/data/services/epg_refresh_service.dart';
import 'package:clubtivi/data/services/server_epg_binding.dart';
import 'package:clubtivi/data/services/server_epg_runtime.dart';
import 'package:clubtivi/data/services/server_epg_sync_service.dart';
import 'package:clubtivi/data/services/website_channel_catalog_service.dart';
import 'package:clubtivi/features/channels/channels_screen.dart';
import 'package:clubtivi/features/channels/compact_category_row.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:clubtivi/features/providers/source_maintenance_coordinator.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' show LiveWidgetController, find;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/player/real.dart' as native;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

class _Database extends db.AppDatabase {
  _Database() : super.forTesting(NativeDatabase.memory());
  final queries = <Map<String, Object?>>[];
  @override
  Future<List<db.Channel>> getChannelCategoryCandidates(
    String category, {
    String? internationalCountry,
    bool publicOnly = false,
  }) async {
    final clock = Stopwatch()..start();
    final rows = await super.getChannelCategoryCandidates(
      category,
      internationalCountry: internationalCountry,
      publicOnly: publicOnly,
    );
    queries.add({
      'category': category,
      'country': internationalCountry,
      'publicOnly': publicOnly,
      'rows': rows.length,
      'elapsedMs': clock.elapsedMilliseconds,
    });
    return rows;
  }
}

class _NoEpg extends EpgRefreshService {
  _NoEpg(super.database);
  @override
  Future<void> addDefaultSources() async {}
  @override
  Future<void> refreshAllSources({bool force = false}) async {}
}

class _Community extends BobTvCommunityService {
  _Community(super.database);
  @override
  Future<void> start() async {}
}

class _Sync extends ServerEpgSyncService {
  _Sync(db.AppDatabase database) : super(database: database);
  int starts = 0;
  @override
  void start() {
    starts++;
  }
}

class _Maintenance extends SourceMaintenanceCoordinator {
  _Maintenance({required super.manager, required super.websiteCatalog});
  @override
  // ignore: overridden_fields
  late final routeStates = ChannelRouteSyncService(
    database: manager.database,
    fetch: (_) async => const BobTvRouteState(retiredUrls: <String>{}),
  );
}

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final output = Directory(Platform.environment['BOBTV_CATALOG_QA_DIR']!);
  await output.create(recursive: true);
  final fixture = File(Platform.environment['BOBTV_CATALOG_QA_VIDEO']!);
  if (!fixture.existsSync()) throw StateError('Missing owned silent video');
  final checks = <String>[];
  final timings = <Map<String, Object?>>[];
  final errors = <String>[];
  void require(bool condition, String name) {
    if (!condition) throw StateError(name);
    checks.add(name);
  }

  Future<void> until(
    String label,
    bool Function() ready, {
    int seconds = 45,
  }) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!ready()) {
      if (DateTime.now().isAfter(end)) throw StateError('timeout:$label');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({
    'last_group': '国际',
    'bobtv_last_international_country': '马来西亚',
    'last_channel_id': '${WebsiteChannelCatalogService.providerId}:live',
    'bobtv_legacy_inventory_migrated_v1': true,
    'bobtv_health_feedback_enabled': false,
  });
  await AppDiagnostics.instance.initialize(
    directoryOverride: Directory('${output.path}/diagnostics'),
  );
  FlutterError.onError = (details) => errors.add(details.exception.toString());
  await PlatformInfo.initialize();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setTitle('BobTV 隔离静音实机验收');
  await windowManager.setSize(const Size(1180, 800));
  final database = _Database();
  const owner = WebsiteChannelCatalogService.providerId;
  await database.upsertProvider(
    db.ProvidersCompanion.insert(id: owner, name: 'QA', type: 'catalog'),
  );
  final rows = <db.ChannelsCompanion>[];
  final identities = <Map<String, Object?>>[];
  for (final entry in {
    '马来西亚': 6,
    '美国': 1200,
    '英国': 3000,
    '日本': 3000,
    '德国': 3000,
  }.entries) {
    for (var i = 0; i < entry.value; i++) {
      final id = entry.key == '马来西亚' && i == 0 ? 'live' : '${entry.key}-$i';
      final name = id == 'live' ? 'QA Silent Live' : 'QA ${entry.key} $i';
      final group = '国际 / ${entry.key} / 电视 / 综合';
      rows.add(
        db.ChannelsCompanion.insert(
          id: '$owner:$id',
          providerId: owner,
          name: name,
          streamUrl: id == 'live'
              ? fixture.uri.toString()
              : 'https://example.invalid/$id.m3u8',
          groupTitle: Value(group),
          sortOrder: Value(i),
        ),
      );
      identities.add({
        'routeId': id,
        'catalogChannelId': id,
        'catalogIdentityHash': 'a' * 64,
        'name': name,
        'group': group,
        'epgId': null,
      });
    }
  }
  await database.upsertChannels(rows);
  await ServerEpgBinding(
    database,
  ).replaceCatalogIdentities('qa-v1', identities);
  await database.upsertEpgSource(
    db.EpgSourcesCompanion.insert(
      id: serverEpgSourceId,
      name: 'QA server guide',
      url: serverEpgManifestUrl,
    ),
  );
  await database.upsertEpgChannels([
    db.EpgChannelsCompanion.insert(
      id: '${serverEpgSourceId}_live',
      sourceId: serverEpgSourceId,
      channelId: 'live',
      displayName: 'QA Silent Live',
    ),
  ]);
  await database.upsertMapping(
    db.EpgMappingsCompanion.insert(
      channelId: '$owner:live',
      providerId: owner,
      epgSourceId: serverEpgSourceId,
      epgChannelId: '${serverEpgSourceId}_live',
      source: const Value('manual'),
      locked: const Value(true),
    ),
  );
  final manager = ProviderManager(database);
  final catalog = WebsiteChannelCatalogService(database: database);
  // Not started: all remote catalogue, source search and private backup work is
  // outside this fixture. Category route-state requests reject its local URLs.
  final coordinator = _Maintenance(manager: manager, websiteCatalog: catalog);
  final sync = _Sync(database);
  sync.state.value = ServerEpgSyncStatus(
    version: 'qa-old',
    coverageEnd: DateTime.utc(2020),
  );
  final runtime = ServerEpgRuntime(
    sync,
    networkChanges: const Stream.empty(),
    observeWindow: false,
  );
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(database),
      providerManagerProvider.overrideWithValue(manager),
      sourceMaintenanceCoordinatorProvider.overrideWithValue(coordinator),
      bobTvCommunityProvider.overrideWithValue(_Community(database)),
      epgRefreshServiceProvider.overrideWithValue(_NoEpg(database)),
      serverEpgRuntimeProvider.overrideWith((ref) {
        runtime.start();
        return runtime;
      }),
    ],
  );
  final service = container.read(playerServiceProvider);
  final player = service.player;
  await until(
    'native player ready',
    () => Directory('${output.path}/diagnostics')
        .listSync()
        .whereType<File>()
        .any(
          (file) =>
              file.path.endsWith('.log') &&
              file.readAsStringSync().contains('"event":"player_ready"'),
        ),
  );
  final nativePlayer = player.platform as native.NativePlayer;
  await nativePlayer.setProperty('ao', 'null');
  await nativePlayer.setProperty('aid', 'no');
  await nativePlayer.setProperty('loop-file', 'inf');
  await service.setVolume(0);
  var positionEvents = 0;
  final positionSubscription = player.stream.position.listen(
    (_) => positionEvents++,
  );
  final clock = Stopwatch()..start();
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: ServerEpgRuntimeHost(
        child: MaterialApp(
          theme: ClubTiviTheme.dark,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const ChannelsScreen(),
        ),
      ),
    ),
  );
  final controls = LiveWidgetController(binding);
  Future<void> chooseCountry(String country) async {
    final row = controls.widget<CompactCategoryRow>(
      find
          .byType(CompactCategoryRow)
          .evaluate()
          .where((e) => (e.widget as CompactCategoryRow).countryIndex)
          .map((e) => find.byWidget(e.widget))
          .first,
    );
    row.options.firstWhere((o) => o.id == country).onTap();
    await binding.endOfFrame;
  }

  try {
    await until(
      'first current-country card',
      () => find.text('QA Silent Live').evaluate().isNotEmpty,
    );
    timings.add({
      'scope': 'initialMalaysia',
      'uiMs': clock.elapsedMilliseconds,
    });
    await until(
      'real decoded video',
      () =>
          service.player.state.width == 160 &&
          service.player.state.height == 96 &&
          service.player.state.position.inMilliseconds > 200,
    );
    require(sync.starts == 1, 'background runtime starts exactly once');
    require(
      find.text('节目表缓存已过期').evaluate().isEmpty,
      'no global expiry banner',
    );
    final activeUrl = service.currentUrl;
    final eventsBefore = positionEvents;
    var timed = Stopwatch()..start();
    await chooseCountry('美国');
    await until('US cards', () => find.text('QA 美国 0').evaluate().isNotEmpty);
    timings.add({'scope': 'USA cold', 'uiMs': timed.elapsedMilliseconds});
    timed = Stopwatch()..start();
    await chooseCountry('马来西亚');
    await until(
      'Malaysia cached cards',
      () => find.text('QA Silent Live').evaluate().isNotEmpty,
    );
    timings.add({'scope': 'Malaysia warm', 'uiMs': timed.elapsedMilliseconds});
    require(
      database.queries.where((q) => q['country'] == '马来西亚').length == 1,
      'warm country switch does not query rows again',
    );
    require(
      database.queries.every(
        (q) =>
            q['publicOnly'] == true &&
            (q['country'] == '马来西亚'
                ? q['rows'] == 6
                : q['country'] == '美国' && q['rows'] == 1200),
      ),
      'queries are scoped to selected public country',
    );
    await controls.tap(
      find.text('QA Silent Live').last,
      kind: PointerDeviceKind.mouse,
    );
    await until(
      'scoped expired guide',
      () => find.textContaining('暂无最新节目表').evaluate().isNotEmpty,
    );
    final now = DateTime.now();
    await database.insertEpgProgrammes([
      db.EpgProgrammesCompanion.insert(
        epgChannelId: '${serverEpgSourceId}_live',
        sourceId: serverEpgSourceId,
        title: 'QA fresh programme',
        start: now.subtract(const Duration(minutes: 1)),
        stop: now.add(const Duration(minutes: 20)),
      ),
    ]);
    sync.state.value = ServerEpgSyncStatus(
      version: 'qa-new',
      coverageEnd: now.add(const Duration(hours: 1)),
    );
    await until(
      'hot programme update',
      () => find.text('QA fresh programme').evaluate().isNotEmpty,
    );
    require(
      find.textContaining('暂无最新节目表').evaluate().isEmpty,
      'fresh guide clears scoped expiry status',
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    require(
      identical(player, service.player) &&
          service.currentUrl == activeUrl &&
          positionEvents > eventsBefore,
      'country and programme updates preserve the active native player',
    );
    require(
      service.player.state.volume == 0 &&
          await nativePlayer.getProperty('ao') == 'null',
      'native playback stays muted with null audio output',
    );
    require(
      (await database.getAllMappings()).single.locked,
      'locked guide mapping retained',
    );
    require(errors.isEmpty, 'no Flutter runtime errors');
    File('${output.path}/result.json').writeAsStringSync(
      jsonEncode({
        'passed': true,
        'platform': Platform.operatingSystem,
        'pid': pid,
        'checkedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'checks': checks,
        'timings': timings,
        'queries': database.queries,
        'totalFixtureRows': rows.length,
        'audioOutput': 'null',
        'volume': 0,
        'ownedAudioFreeFixture': true,
        'productionDataModified': false,
        'positionEvents': positionEvents,
      }),
    );
    await service.stop();
    await positionSubscription.cancel();
    runtime.dispose();
    await service.dispose();
    await database.close();
    await windowManager.destroy();
    exit(0);
  } catch (error, stack) {
    File('${output.path}/result.json').writeAsStringSync(
      jsonEncode({
        'passed': false,
        'error': error.toString(),
        'stack': stack.toString(),
        'checks': checks,
        'queries': database.queries,
        'timings': timings,
        'flutterErrors': errors,
      }),
    );
    await service.stop();
    exit(1);
  }
}
