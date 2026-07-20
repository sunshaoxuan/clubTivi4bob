import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_diagnostics.dart';
import '../../data/services/bundled_source_snapshot_service.dart';
import '../../data/services/github_source_monitor.dart';
import '../../data/services/github_ai_crawler_service.dart';
import '../../data/services/source_maintenance_service.dart';
import 'default_provider_bootstrap.dart';
import 'provider_manager.dart';

class SourceMaintenanceCoordinator {
  final ProviderManager manager;
  final GitHubSourceMonitor githubMonitor;
  final SourceMaintenanceService maintenanceService;
  final GitHubAiCrawlerService githubAiCrawler;
  final BundledSourceSnapshotService bundledSourceSnapshot;

  Timer? _timer;
  Timer? _startupTimer;
  Timer? _snapshotTimer;
  bool _running = false;

  SourceMaintenanceCoordinator({
    required this.manager,
    required this.githubMonitor,
    required this.maintenanceService,
    required this.githubAiCrawler,
    required this.bundledSourceSnapshot,
  });

  void start() {
    if (_timer != null) return;
    _snapshotTimer = Timer(
      const Duration(seconds: 2),
      () => unawaited(_importBundledSnapshot()),
    );
    // Large source refreshes stay away from the first interactive frame.
    _startupTimer = Timer(const Duration(minutes: 1), () => unawaited(_run()));
    _timer = Timer.periodic(
      DefaultProviderBootstrap.refreshInterval,
      (_) => unawaited(_run()),
    );
  }

  Future<void> _importBundledSnapshot() async {
    try {
      await bundledSourceSnapshot.run();
    } catch (error, stackTrace) {
      AppDiagnostics.instance.recordError(
        'bundled_source_snapshot',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    final database = manager.database;
    try {
      try {
        await bundledSourceSnapshot.run();
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
      await DefaultProviderBootstrap(
        database: database,
        manager: manager,
      ).run();
      await maintenanceService.run();
      await githubAiCrawler.run();
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
    _startupTimer?.cancel();
    _timer?.cancel();
    githubMonitor.dispose();
    maintenanceService.dispose();
    githubAiCrawler.dispose();
  }
}

final sourceMaintenanceCoordinatorProvider =
    Provider<SourceMaintenanceCoordinator>((ref) {
      final database = ref.watch(databaseProvider);
      final coordinator = SourceMaintenanceCoordinator(
        manager: ref.watch(providerManagerProvider),
        githubMonitor: GitHubSourceMonitor(database: database),
        maintenanceService: SourceMaintenanceService(database: database),
        githubAiCrawler: GitHubAiCrawlerService(database: database),
        bundledSourceSnapshot: BundledSourceSnapshotService(database: database),
      );
      coordinator.start();
      ref.onDispose(coordinator.dispose);
      return coordinator;
    });
