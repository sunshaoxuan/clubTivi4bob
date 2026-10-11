import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/services/source_maintenance_service.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'local network retirement never deletes a shared public route',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final service = SourceMaintenanceService(database: database);
      try {
        await database.upsertProvider(
          db.ProvidersCompanion.insert(
            id: 'bobtv-channel-catalog',
            name: 'Public',
            type: 'm3u',
          ),
        );
        await database.upsertChannels([
          db.ChannelsCompanion.insert(
            id: 'news',
            providerId: 'bobtv-channel-catalog',
            name: 'News',
            streamUrl: 'https://media.example.org/news.m3u8',
          ),
        ]);
        await database.upsertStreamChecks([
          db.StreamChecksCompanion.insert(
            streamUrl: 'https://media.example.org/news.m3u8',
            providerId: 'bobtv-channel-catalog',
            channelId: 'news',
            retired: const Value(true),
            consecutiveFailures: const Value(5),
          ),
        ]);
        await service.run();
        expect(await database.getAllChannels(), hasLength(1));
        expect(
          (await database.pendingSharedEvents()).where(
            (e) => e['kind'] == 'delete',
          ),
          isEmpty,
        );
      } finally {
        service.dispose();
        await database.close();
      }
    },
  );
  group('SourceMaintenancePolicy', () {
    final now = DateTime.utc(2026, 7, 19, 12);

    test('does not retire before three failures', () {
      final decision = SourceMaintenancePolicy.evaluate(
        success: false,
        previousFailures: 1,
        previousFirstFailureAt: now.subtract(const Duration(hours: 8)),
        previousLastSuccessAt: null,
        now: now,
      );
      expect(decision.consecutiveFailures, 2);
      expect(decision.retired, isFalse);
    });

    test('does not retire before the six hour safety window', () {
      final decision = SourceMaintenancePolicy.evaluate(
        success: false,
        previousFailures: 2,
        previousFirstFailureAt: now.subtract(const Duration(hours: 5)),
        previousLastSuccessAt: null,
        now: now,
      );
      expect(decision.consecutiveFailures, 3);
      expect(decision.retired, isFalse);
    });

    test('retires after three failures across at least six hours', () {
      final decision = SourceMaintenancePolicy.evaluate(
        success: false,
        previousFailures: 2,
        previousFirstFailureAt: now.subtract(const Duration(hours: 6)),
        previousLastSuccessAt: null,
        now: now,
      );
      expect(decision.retired, isTrue);
    });

    test('success clears accumulated failures', () {
      final decision = SourceMaintenancePolicy.evaluate(
        success: true,
        previousFailures: 4,
        previousFirstFailureAt: now.subtract(const Duration(hours: 24)),
        previousLastSuccessAt: null,
        now: now,
      );
      expect(decision.consecutiveFailures, 0);
      expect(decision.firstFailureAt, isNull);
      expect(decision.lastSuccessAt, now);
      expect(decision.retired, isFalse);
    });
  });
}
