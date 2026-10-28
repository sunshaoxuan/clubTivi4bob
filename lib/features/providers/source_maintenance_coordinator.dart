import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_diagnostics.dart';
import '../../data/services/bundled_source_snapshot_service.dart';
import '../../data/services/source_maintenance_service.dart';
import '../../data/services/website_channel_catalog_service.dart';
import '../../data/services/channel_inventory_sync_service.dart';
import 'provider_manager.dart';
import '../../data/services/stream_alternatives_service.dart';
import '../../data/services/regional_route_service.dart';
import '../../data/services/device_favorites_sync_service.dart';
import '../../data/services/bobtv_api_client.dart';
import '../../data/services/channel_route_sync_service.dart';

class SourceMaintenanceCoordinator {
  final ProviderManager manager;
  SourceMaintenanceService? _maintenanceService;
  BundledSourceSnapshotService? _bundledSourceSnapshot;
  // Source-management tools allocate their HTTP clients only on explicit use.
  SourceMaintenanceService get maintenanceService => _maintenanceService ??=
      SourceMaintenanceService(database: manager.database);
  BundledSourceSnapshotService get bundledSourceSnapshot =>
      _bundledSourceSnapshot ??= BundledSourceSnapshotService(
        database: manager.database,
      );
  final WebsiteChannelCatalogService websiteCatalog;
  late final routeStates = ChannelRouteSyncService(
    database: manager.database,
    fetch: (urls) async {
      final client = BobTvApiClient(baseUri: websiteCatalog.api.baseUri);
      try {
        return await client
            .fetchRouteState(urls)
            .timeout(const Duration(seconds: 3));
      } finally {
        client.close();
      }
    },
    onCatalogChanged: () => unawaited(websiteCatalog.sync()),
  );
  late final inventory =
      _inventoryOverride ??
      ChannelInventorySyncService(database: manager.database);
  final ChannelInventorySyncService? _inventoryOverride;
  final RegionalRouteService? regionalRoutes;
  late final privateFavorites =
      _privateFavoritesOverride ??
      DeviceFavoritesSyncService(database: manager.database);
  final DeviceFavoritesSyncService? _privateFavoritesOverride;
  bool get sourceManagementInitialized =>
      _maintenanceService != null || _bundledSourceSnapshot != null;

  Timer? _snapshotTimer;
  Timer? _catalogTimer;
  Timer? _changesTimer;
  Future<void>? _initialization;
  Future<void>? _bootstrap;
  Future<void>? _changes;
  bool _changesRunning = false;
  bool _started = false;
  bool _disposed = false;

  SourceMaintenanceCoordinator({
    required this.manager,
    required this.websiteCatalog,
    ChannelInventorySyncService? inventory,
    this.regionalRoutes,
    DeviceFavoritesSyncService? privateFavorites,
  }) : _inventoryOverride = inventory,
       _privateFavoritesOverride = privateFavorites;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    unawaited(
      _initialization = regionalRoutes?.initialize() ?? Future<void>.value(),
    );
    AppDiagnostics.instance.log('background_work_policy', {
      'globalGithubScanning': false,
      'globalRouteScanning': false,
      'sourceManagement': 'on_demand',
      'sharedCatalogPollSeconds': 60,
      'sharedChangesPollSeconds': 15,
    });
    _snapshotTimer = Timer(
      const Duration(seconds: 2),
      () => unawaited(
        (_bootstrap = _importInitialSnapshot()).catchError(
          (Object error, StackTrace stack) => AppDiagnostics.instance
              .recordError('shared_catalog_bootstrap', error, stack),
        ),
      ),
    );
    // A catalog revision reaches running clients without waiting for the
    // slower provider discovery and health-maintenance cycle.
    _catalogTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(_syncSharedChanges(pull: true)),
    );
    _changesTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_syncSharedChanges());
      unawaited(privateFavorites.sync());
    });
    // Public discovery and full-catalog validation belong to the server.
    // Entering advanced mode does not implicitly start those workloads either.
    unawaited(privateFavorites.sync());
  }

  Future<void> _syncSharedChanges({bool pull = false}) {
    if (_disposed) return Future.value();
    return _changes ??= _runSharedChanges(
      pull: pull,
    ).whenComplete(() => _changes = null);
  }

  Future<void> _runSharedChanges({bool pull = false}) async {
    if (_changesRunning || _disposed) return;
    _changesRunning = true;
    try {
      if (pull) await regionalRoutes?.refresh();
      final sent = await inventory.flushEvents();
      if (pull || sent > 0) await websiteCatalog.sync();
      if (pull) await inventory.syncLegacyInventoryOnce();
    } catch (error, stack) {
      AppDiagnostics.instance.recordError('shared_catalog_sync', error, stack);
    } finally {
      _changesRunning = false;
    }
  }

  Future<void> _importInitialSnapshot() async {
    if (_disposed) return;
    // A small preclassified starter is visible before the first network round trip.
    if (!(await manager.database.getAllProviders()).any(
      (p) => p.id == WebsiteChannelCatalogService.providerId,
    )) {
      await websiteCatalog.importBundled();
    }
    if (_disposed) return;
    await websiteCatalog.sync();
    if (_disposed) return;
    if (!(await manager.database.getAllProviders()).any(
      (p) => p.id == WebsiteChannelCatalogService.providerId,
    )) {
      await _importBundledSnapshot();
    }
    if (_disposed) return;
    await inventory.syncLegacyInventoryOnce();
  }

  Future<void> _importBundledSnapshot() async {
    try {
      final purged = await manager.database
          .purgeRejectedNonTelevisionChannels();
      if (purged > 0) {
        AppDiagnostics.instance.log('non_television_sources_purged', {
          'deletedChannels': purged,
        });
      }
      await bundledSourceSnapshot.run();
    } catch (error, stackTrace) {
      AppDiagnostics.instance.recordError(
        'bundled_source_snapshot',
        error,
        stackTrace,
      );
    }
  }

  Future<void> shutdown() async {
    dispose();
    await Future.wait<Object?>([
      ?_initialization,
      ?_bootstrap,
      ?_changes,
      websiteCatalog.shutdown(),
      routeStates.shutdown(),
      inventory.shutdown(),
      privateFavorites.shutdown(),
      if (regionalRoutes != null) regionalRoutes!.shutdown(),
    ]);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _snapshotTimer?.cancel();
    _catalogTimer?.cancel();
    _changesTimer?.cancel();
    _maintenanceService?.dispose();
    websiteCatalog.dispose();
    routeStates.dispose();
    inventory.dispose();
    privateFavorites.dispose();
    regionalRoutes?.dispose();
  }
}

final sourceMaintenanceCoordinatorProvider =
    Provider<SourceMaintenanceCoordinator>((ref) {
      final database = ref.watch(databaseProvider);
      final tracker = ref.read(streamHealthTrackerProvider);
      final regional = RegionalRouteService(
        tracker: tracker,
        onNetworkChanged: (networkId) async {
          await database.switchAvailabilityNetwork(networkId);
        },
      );
      tracker.onRegionalObservation = (url, observation) {
        unawaited(
          database
              .queueSharedEvent(
                url,
                'health',
                regional.observation(observation),
              )
              .catchError(
                (Object error, StackTrace stack) => AppDiagnostics.instance
                    .recordError('queue_shared_health', error, stack),
              ),
        );
      };
      final coordinator = SourceMaintenanceCoordinator(
        manager: ref.watch(providerManagerProvider),
        regionalRoutes: regional,
        websiteCatalog: WebsiteChannelCatalogService(
          database: database,
          onSharedScores: tracker.setSharedScores,
        ),
      );
      coordinator.start();
      ref.onDispose(() {
        tracker.onRegionalObservation = null;
        coordinator.dispose();
      });
      return coordinator;
    });
