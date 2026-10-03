import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_diagnostics.dart';
import '../../data/services/bundled_source_snapshot_service.dart';
import '../../data/services/github_source_monitor.dart';
import '../../data/services/github_ai_crawler_service.dart';
import '../../data/services/source_maintenance_service.dart';
import '../../data/services/website_channel_catalog_service.dart';
import '../../data/services/channel_inventory_sync_service.dart';
import 'default_provider_bootstrap.dart';
import 'provider_manager.dart';
import '../../data/services/stream_alternatives_service.dart';

class SourceMaintenanceCoordinator {
  final ProviderManager manager;
  final GitHubSourceMonitor githubMonitor;
  final SourceMaintenanceService maintenanceService;
  final GitHubAiCrawlerService githubAiCrawler;
  final BundledSourceSnapshotService bundledSourceSnapshot;
  final WebsiteChannelCatalogService websiteCatalog;
  late final inventory = ChannelInventorySyncService(
    database: manager.database,
  );

  Timer? _timer;
  Timer? _startupTimer;
  Timer? _snapshotTimer;
  Timer? _catalogTimer;
  Timer? _healthTimer;
  Timer? _changesTimer;
  bool _changesRunning = false;
  bool _running = false;
  bool _healthRunning = false;

  SourceMaintenanceCoordinator({
    required this.manager,
    required this.githubMonitor,
    required this.maintenanceService,
    required this.githubAiCrawler,
    required this.bundledSourceSnapshot,
    required this.websiteCatalog,
  });

  void start() {
    if (_timer != null) return;
    _snapshotTimer = Timer(
      const Duration(seconds: 2),
      () => unawaited(_importInitialSnapshot()),
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
    // Large source refreshes stay away from the first interactive frame.
    _startupTimer = Timer(const Duration(minutes: 1), () => unawaited(_run()));
    _timer = Timer.periodic(
      DefaultProviderBootstrap.refreshInterval,
      (_) => unawaited(_run()),
    );
    _healthTimer = Timer.periodic(
      const Duration(hours: 1),
      (_) => unawaited(_runHealthMaintenance()),
    );
  }

  Future<void> _syncSharedChanges({bool pull = false}) async {
    if (_changesRunning) return;
    _changesRunning = true;
    try {
      final sent = await inventory.flushEvents();
      if (pull || sent > 0) await websiteCatalog.sync();
    } finally {
      _changesRunning = false;
    }
  }

  Future<void> _importInitialSnapshot() async {
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
    unawaited(inventory.sync());
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

  Future<void> _runHealthMaintenance() async {
    if (_running || _healthRunning) return;
    _healthRunning = true;
    try {
      await maintenanceService.run();
    } catch (error, stackTrace) {
      AppDiagnostics.instance.recordError(
        'source_health_maintenance',
        error,
        stackTrace,
      );
    } finally {
      _healthRunning = false;
    }
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    final database = manager.database;
    try {
      try {
        final purged = await database.purgeRejectedNonTelevisionChannels();
        if (purged > 0) {
          AppDiagnostics.instance.log('non_television_sources_purged', {
            'deletedChannels': purged,
          });
        }
        await websiteCatalog.sync();
        final hasSharedCatalog = (await database.getAllProviders()).any(
          (provider) => provider.id == WebsiteChannelCatalogService.providerId,
        );
        if (!hasSharedCatalog) {
          await bundledSourceSnapshot.run();
        }
      } catch (error, stackTrace) {
        AppDiagnostics.instance.recordError(
          'bundled_source_snapshot',
          error,
          stackTrace,
        );
      }
      final providers = await database.getAllProviders();
      await githubMonitor.syncOrigins(providers);
      await githubMonitor.scanForUpdates(manager);
      if (!(await database.getAllProviders()).any(
        (provider) => provider.id == WebsiteChannelCatalogService.providerId,
      )) {
        await DefaultProviderBootstrap(
          database: database,
          manager: manager,
        ).run();
      }
      await maintenanceService.run();
      await githubAiCrawler.run();
      await inventory.sync();
    } catch (error, stackTrace) {
      AppDiagnostics.instance.recordError(
        'source_maintenance_coordinator',
        error,
        stackTrace,
      );
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _snapshotTimer?.cancel();
    _catalogTimer?.cancel();
    _startupTimer?.cancel();
    _healthTimer?.cancel();
    _timer?.cancel();
    _changesTimer?.cancel();
    githubMonitor.dispose();
    maintenanceService.dispose();
    githubAiCrawler.dispose();
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
        githubMonitor: GitHubSourceMonitor(database: database),
        maintenanceService: SourceMaintenanceService(database: database),
        githubAiCrawler: GitHubAiCrawlerService(database: database),
        bundledSourceSnapshot: BundledSourceSnapshotService(database: database),
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
