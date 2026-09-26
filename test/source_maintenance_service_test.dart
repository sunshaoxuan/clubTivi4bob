import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/services/source_maintenance_service.dart';

void main() {
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
