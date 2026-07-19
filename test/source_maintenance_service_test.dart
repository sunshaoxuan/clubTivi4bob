import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/services/source_maintenance_service.dart';

void main() {
  group('SourceMaintenancePolicy', () {
    final now = DateTime.utc(2026, 7, 19, 12);

    test('does not retire before five failures', () {
      final decision = SourceMaintenancePolicy.evaluate(
        success: false,
        previousFailures: 3,
        previousFirstFailureAt: now.subtract(const Duration(days: 2)),
        previousLastSuccessAt: null,
        now: now,
      );
      expect(decision.consecutiveFailures, 4);
      expect(decision.retired, isFalse);
    });

    test('does not retire before the 24 hour safety window', () {
      final decision = SourceMaintenancePolicy.evaluate(
        success: false,
        previousFailures: 4,
        previousFirstFailureAt: now.subtract(const Duration(hours: 23)),
        previousLastSuccessAt: null,
        now: now,
      );
      expect(decision.consecutiveFailures, 5);
      expect(decision.retired, isFalse);
    });

    test('retires after five failures across at least 24 hours', () {
      final decision = SourceMaintenancePolicy.evaluate(
        success: false,
        previousFailures: 4,
        previousFirstFailureAt: now.subtract(const Duration(hours: 24)),
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
