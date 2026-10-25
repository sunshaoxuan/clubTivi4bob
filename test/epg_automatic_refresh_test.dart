import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/epg_refresh_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class PeriodicGuide extends EpgRefreshService {
  PeriodicGuide(super.database);
  int checks = 0;
  @override
  Future<void> refreshAllSources({bool force = false}) async { checks++; }
}

void main() {
  testWidgets('XMLTV keeps checking while open and stops before database close', (tester) async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final service = PeriodicGuide(database);
    service.startAutomaticRefresh(checkEvery: const Duration(seconds: 10));
    service.startAutomaticRefresh(checkEvery: const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 31));
    expect(service.checks, 3);
    await service.shutdown();
    await tester.pump(const Duration(hours: 5));
    expect(service.checks, 3);
    await database.close();
  });
}
