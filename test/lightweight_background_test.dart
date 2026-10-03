import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_inventory_sync_service.dart';
import 'package:clubtivi/data/services/website_channel_catalog_service.dart';
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:clubtivi/features/providers/source_maintenance_coordinator.dart';
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MigrationInventory extends ChannelInventorySyncService {
  MigrationInventory(db.AppDatabase database)
    : super(database: database, fingerprintOverride: 'a' * 64);
  int scans = 0;
  bool fail = false;
  @override
  Future<void> sync({bool refreshAfterRunning = false}) async {
    scans++;
    state.value = WebsiteCatalogProgress(complete: !fail, error: fail);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'startup has only shared pull/upload timers and no management clients',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final catalog = WebsiteChannelCatalogService(database: database);
      final coordinator = SourceMaintenanceCoordinator(
        manager: ProviderManager(database),
        websiteCatalog: catalog,
      );
      fakeAsync((clock) {
        coordinator.start();
        coordinator.start();
        expect(clock.periodicTimerCount, 2);
        expect(clock.nonPeriodicTimerCount, 1);
        expect(coordinator.sourceManagementInitialized, false);
        coordinator.dispose();
        expect(clock.pendingTimers, isEmpty);
        expect(coordinator.sourceManagementInitialized, false);
      });
      await database.close();
    },
  );

  test(
    'fresh shared-catalog installation never scans a full inventory',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      await database.upsertProvider(
        db.ProvidersCompanion.insert(
          id: WebsiteChannelCatalogService.providerId,
          name: 'Website',
          type: 'm3u',
        ),
      );
      final service = MigrationInventory(database);
      await service.syncLegacyInventoryOnce();
      await service.syncLegacyInventoryOnce();
      expect(service.scans, 0);
      service.dispose();
      await database.close();
    },
  );

  test(
    'legacy inventory migrates once across launches and retries failures',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      await database.upsertProvider(
        db.ProvidersCompanion.insert(
          id: 'github-ai-crawler',
          name: 'Legacy GitHub',
          type: 'm3u',
        ),
      );
      final first = MigrationInventory(database)..fail = true;
      await first.syncLegacyInventoryOnce();
      first.fail = false;
      await first.syncLegacyInventoryOnce();
      await first.syncLegacyInventoryOnce();
      expect(first.scans, 2);
      first.dispose();
      final next = MigrationInventory(database);
      await next.syncLegacyInventoryOnce();
      expect(next.scans, 0);
      next.dispose();
      await database.close();
    },
  );
}
