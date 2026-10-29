import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/app/theme.dart';
import 'package:clubtivi/core/app_diagnostics.dart';
import 'package:clubtivi/core/platform_info.dart';
import 'package:clubtivi/data/datasources/local/database.dart';
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/bobtv_community_service.dart';
import 'package:clubtivi/data/services/channel_inventory_sync_service.dart';
import 'package:clubtivi/data/services/device_favorites_sync_service.dart';
import 'package:clubtivi/data/services/epg_refresh_service.dart';
import 'package:clubtivi/data/services/server_task_client.dart';
import 'package:clubtivi/data/services/stream_alternatives_service.dart';
import 'package:clubtivi/data/services/website_channel_catalog_service.dart';
import 'package:clubtivi/features/channels/channels_screen.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:clubtivi/features/providers/source_maintenance_coordinator.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' show LiveWidgetController, find;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/player/real.dart' as native;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

// Executes the production ChannelsScreen, player, recovery and DB synchronizer.
// Only the catalog/API, preferences, diagnostics and database are isolated.
// Fixtures contain no audio track; native output is additionally set to null.
class _NoEpg extends EpgRefreshService {
  _NoEpg(super.database);
  @override
  Future<void> addDefaultSources() async {}
  @override
  Future<void> refreshAllSources({bool force = false}) async {}
}

class _Tasks extends ServerTaskClient {
  _Tasks(Uri uri) : super(baseUri: uri);
  final submitted = <String, String>{};
  @override
  Future<Map<String, dynamic>> submit(
    String kind,
    List<Map<String, String>> inputs,
  ) async {
    final value = await super.submit(kind, inputs);
    submitted[inputs.single['channelId']!] = value['id'] as String;
    return value;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final output = Directory(Platform.environment['BOBTV_ACCEPTANCE_REPORT']!);
  await output.create(recursive: true);
  final report = File('${output.path}/events.jsonl');
  void record(
    String event, [
    Map<String, Object?> values = const {},
  ]) => report.writeAsStringSync(
    '${jsonEncode({'at': DateTime.now().toUtc().toIso8601String(), 'pid': pid, 'event': event, ...values})}\n',
    mode: FileMode.append,
    flush: true,
  );
  Future<void> until(
    String label,
    bool Function() ready, {
    int seconds = 180,
  }) async {
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) throw StateError('timeout:$label');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    record(label);
  }

  final platform = Platform.isWindows ? 'windows' : 'mac';
  final uri = Uri.parse(Platform.environment['BOBTV_ACCEPTANCE_API']!);
  final database = AppDatabase.forTesting(
    NativeDatabase(File('${output.path}/catalog.sqlite')),
  );
  // The native acceptance app must never read or write the daily app's preferences.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({
    'last_group': '数字',
    'bobtv_legacy_inventory_migrated_v1': true,
    'bobtv_health_feedback_enabled': false,
  });
  await AppDiagnostics.instance.initialize(
    directoryOverride: Directory('${output.path}/diagnostics'),
  );
  FlutterError.onError = (details) =>
      record('flutter_error', {'error': details.exception.toString()});
  await PlatformInfo.initialize();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setTitle('BobTV isolated silent recovery acceptance');
  await windowManager.setSize(const Size(1180, 760));
  final api = BobTvApiClient(baseUri: uri);
  final manager = ProviderManager(database);
  final catalog = WebsiteChannelCatalogService(database: database, api: api);
  await catalog.sync();
  if (catalog.lastError != null)
    throw StateError('initial_catalog:${catalog.lastError}');
  final imported = await database.getChannelsForProvider(
    WebsiteChannelCatalogService.providerId,
  );
  final initial = imported.firstWhere((c) => c.name == 'QA $platform-recover');
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('last_channel_id', initial.id);
  final tasks = _Tasks(uri);
  final coordinator = SourceMaintenanceCoordinator(
    manager: manager,
    websiteCatalog: catalog,
    inventory: ChannelInventorySyncService(
      database: database,
      api: api,
      fingerprintOverride: 'b' * 64,
    ),
    privateFavorites: DeviceFavoritesSyncService(
      database: database,
      api: api,
      backupEnabled: () async => false,
    ),
  );
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(database),
      providerManagerProvider.overrideWithValue(manager),
      sourceMaintenanceCoordinatorProvider.overrideWithValue(coordinator),
      serverTaskClientProvider.overrideWithValue(tasks),
      bobTvCommunityProvider.overrideWithValue(
        BobTvCommunityService(database, api: api),
      ),
      epgRefreshServiceProvider.overrideWithValue(_NoEpg(database)),
    ],
  );
  final service = container.read(playerServiceProvider);
  final tracker = container.read(streamHealthTrackerProvider);
  service.player;
  await until(
    'native_player_ready',
    () => Directory('${output.path}/diagnostics')
        .listSync()
        .whereType<File>()
        .any(
          (file) =>
              file.path.endsWith('.log') &&
              file.readAsStringSync().contains('"event":"player_ready"'),
        ),
    seconds: 30,
  );
  await (service.player.platform as native.NativePlayer).setProperty(
    'ao',
    'null',
  );
  await service.setVolume(0);
  final scoreBefore = tracker.getScore(initial.streamUrl);
  record('initial_catalog', {
    'rows': imported.length,
    'version': prefs.getString('bobtv_website_catalog_version_v1'),
    'volume': service.player.state.volume,
  });
  coordinator.start();
  runApp(
    UncontrolledProviderScope(
      container: container,
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
  );
  try {
    await until(
      'server_recovery_requested',
      () => tasks.submitted.containsKey('$platform-recover'),
    );
    await until(
      'automatic_replacement_playing',
      () =>
          service.currentUrl?.endsWith('/$platform-recover.m3u8') == true &&
          service.player.state.width == 320 &&
          service.player.state.height == 240 &&
          service.player.state.position > const Duration(seconds: 2),
    );
    final after = await database.publicRoutesForCatalogChannel(
      '$platform-recover',
    );
    final receipt = await tasks.result(tasks.submitted['$platform-recover']!);
    final scoreAfter = tracker.getScore(initial.streamUrl);
    if (after.length != 2 || scoreAfter >= scoreBefore)
      throw StateError(
        'admission_or_demotion_failed:$scoreBefore:$scoreAfter:${after.length}',
      );
    record('automatic_recovery_passed', {
      'routes': after.length,
      'scoreBefore': scoreBefore,
      'scoreAfter': scoreAfter,
      'receipt': receipt,
      'positionMs': service.player.state.position.inMilliseconds,
      'width': service.player.state.width,
      'height': service.player.state.height,
      'version': prefs.getString('bobtv_website_catalog_version_v1'),
    });
    final controls = LiveWidgetController(WidgetsBinding.instance);
    await until(
      'cancel_card_visible',
      () => find.text('QA $platform-cancel').evaluate().isNotEmpty,
      seconds: 20,
    );
    await controls.tap(find.text('QA $platform-cancel').first);
    await until(
      'second_recovery_requested',
      () => tasks.submitted.containsKey('$platform-cancel'),
    );
    // Choosing the already playing card changes intent and cancels its failed preview.
    await controls.tap(find.text('QA $platform-recover').last);
    final activeUrl = service.currentUrl;
    final position = service.player.state.position;
    await Future<void>.delayed(const Duration(seconds: 45));
    await catalog.sync();
    final cancelledRoutes = await database.publicRoutesForCatalogChannel(
      '$platform-cancel',
    );
    if (cancelledRoutes.length != 2 ||
        service.currentUrl != activeUrl ||
        service.player.state.position <=
            position + const Duration(seconds: 10)) {
      throw StateError('selection_preservation_failed');
    }
    record('selection_preservation_passed', {
      'routes': cancelledRoutes.length,
      'positionBeforeMs': position.inMilliseconds,
      'positionAfterMs': service.player.state.position.inMilliseconds,
      'unchangedActiveUrl': true,
      'sameProcess': true,
    });
    File('${output.path}/result.json').writeAsStringSync(
      jsonEncode({
        'passed': true,
        'platform': platform,
        'pid': pid,
        'audio': 'fixture_without_audio_and_null_output',
        'nativeDimensions': [
          service.player.state.width,
          service.player.state.height,
        ],
        'automaticRetry': true,
        'catalogImport': true,
        'failureDemotion': true,
        'selectionPreservation': true,
        'androidPhysicalTest': false,
      }),
    );
    record('passed');
    await service.stop();
    await coordinator.shutdown();
    await service.dispose();
    await database.close();
    await windowManager.destroy();
    exit(0);
  } catch (error, stack) {
    record('failed', {'error': error.toString(), 'stack': stack.toString()});
    File('${output.path}/result.json').writeAsStringSync(
      jsonEncode({'passed': false, 'error': error.toString()}),
    );
    await service.stop();
    exit(1);
  }
}
