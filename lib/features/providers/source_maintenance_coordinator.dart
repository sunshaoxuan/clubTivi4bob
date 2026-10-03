import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_diagnostics.dart';
import '../../data/services/bundled_source_snapshot_service.dart';
import '../../data/services/github_source_monitor.dart';
import '../../data/services/github_ai_crawler_service.dart';
import '../../data/services/source_maintenance_service.dart';
import '../../data/services/website_channel_catalog_service.dart';
import '../../data/services/channel_inventory_sync_service.dart';
import 'provider_manager.dart';
import '../../data/services/stream_alternatives_service.dart';

class SourceMaintenanceCoordinator {
  final ProviderManager manager;
  GitHubSourceMonitor? _githubMonitor;
  SourceMaintenanceService? _maintenanceService;
  GitHubAiCrawlerService? _githubAiCrawler;
  BundledSourceSnapshotService? _bundledSourceSnapshot;
  // Source-management tools allocate their HTTP clients only on explicit use.
  GitHubSourceMonitor get githubMonitor =>
      _githubMonitor ??= GitHubSourceMonitor(database: manager.database);
  SourceMaintenanceService get maintenanceService => _maintenanceService ??=
      SourceMaintenanceService(database: manager.database);
  GitHubAiCrawlerService get githubAiCrawler =>
      _githubAiCrawler ??= GitHubAiCrawlerService(database: manager.database);
  BundledSourceSnapshotService get bundledSourceSnapshot =>
      _bundledSourceSnapshot ??= BundledSourceSnapshotService(
        database: manager.database,
      );
  final WebsiteChannelCatalogService websiteCatalog;
  late final inventory =
      _inventoryOverride ??
      ChannelInventorySyncService(database: manager.database);
  final ChannelInventorySyncService? _inventoryOverride;
  bool get sourceManagementInitialized =>
      _githubMonitor != null ||
      _maintenanceService != null ||
      _githubAiCrawler != null ||
      _bundledSourceSnapshot != null;

  Timer? _snapshotTimer;
  Timer? _catalogTimer;
  Timer? _changesTimer;
  bool _changesRunning = false;
  bool _started = false;
  bool _disposed = false;

  SourceMaintenanceCoordinator({
    required this.manager,
    required this.websiteCatalog,
    ChannelInventorySyncService? inventory,
  }) : _inventoryOverride = inventory;

  void start() {
    if (_started || _disposed) return;
    _started = true;
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
        _importInitialSnapshot().catchError(
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
    _changesTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_syncSharedChanges()),
    );
    // Public discovery and full-catalog validation belong to the server.
    // Entering advanced mode does not implicitly start those workloads either.
  }

  Future<void> _syncSharedChanges({bool pull = false}) async {
    if (_changesRunning || _disposed) return;
    _changesRunning = true;
    try {
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
    await websiteCatalog.sync();
    if (!(await manager.database.getAllProviders()).any(
      (p) => p.id == WebsiteChannelCatalogService.providerId,
    )) {
      await _importBundledSnapshot();
    }
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

  void dispose() {
    _disposed = true;
    _snapshotTimer?.cancel();
    _catalogTimer?.cancel();
    _changesTimer?.cancel();
    _githubMonitor?.dispose();
    _maintenanceService?.dispose();
    _githubAiCrawler?.dispose();
    websiteCatalog.dispose();
    inventory.dispose();
  }
}

final sourceMaintenanceCoordinatorProvider =
    Provider<SourceMaintenanceCoordinator>((ref) {
      final database = ref.watch(databaseProvider);
      final tracker = ref.read(streamHealthTrackerProvider);
      tracker.onSharedObservation = (url, success, failure) {
        unawaited(
          database
              .queueSharedEvent(url, 'health', {
                'success': success,
                'failure': failure,
              })
              .catchError(
                (Object error, StackTrace stack) => AppDiagnostics.instance
                    .recordError('queue_shared_health', error, stack),
              ),
        );
      };
      final coordinator = SourceMaintenanceCoordinator(
        manager: ref.watch(providerManagerProvider),
        websiteCatalog: WebsiteChannelCatalogService(
          database: database,
          onSharedScores: tracker.setSharedScores,
        ),
      );
      coordinator.start();
      ref.onDispose(() {
        tracker.onSharedObservation = null;
        coordinator.dispose();
      });
      return coordinator;
    });
