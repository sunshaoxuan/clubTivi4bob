import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_diagnostics.dart';
import '../../data/services/github_source_monitor.dart';
import '../../data/services/source_maintenance_service.dart';
import 'default_provider_bootstrap.dart';
import 'provider_manager.dart';

class SourceMaintenanceCoordinator {
  final ProviderManager manager;
  final GitHubSourceMonitor githubMonitor;
  final SourceMaintenanceService maintenanceService;

  Timer? _timer;
  bool _running = false;

  SourceMaintenanceCoordinator({
    required this.manager,
    required this.githubMonitor,
    required this.maintenanceService,
  });

  void start() {
    if (_timer != null) return;
    unawaited(_run());
    _timer = Timer.periodic(
      DefaultProviderBootstrap.refreshInterval,
      (_) => unawaited(_run()),
    );
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    final database = manager.database;
    try {
      final providers = await database.getAllProviders();
      await githubMonitor.syncOrigins(providers);
      await githubMonitor.scanForUpdates(manager);
      await DefaultProviderBootstrap(
        database: database,
        manager: manager,
      ).run();
      await maintenanceService.run();
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
    _timer?.cancel();
    githubMonitor.dispose();
    maintenanceService.dispose();
  }
}

final sourceMaintenanceCoordinatorProvider =
    Provider<SourceMaintenanceCoordinator>((ref) {
      final database = ref.watch(databaseProvider);
      final coordinator = SourceMaintenanceCoordinator(
        manager: ref.watch(providerManagerProvider),
        githubMonitor: GitHubSourceMonitor(database: database),
        maintenanceService: SourceMaintenanceService(database: database),
      );
      coordinator.start();
      ref.onDispose(coordinator.dispose);
      return coordinator;
    });
