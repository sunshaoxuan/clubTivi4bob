import 'dart:io';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_inventory_sync_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const path = String.fromEnvironment('BOBTV_INVENTORY_DATABASE');
  const fingerprint = String.fromEnvironment('BOBTV_INVENTORY_FINGERPRINT');
  test(
    'contribute an existing public catalog through the production uploader',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = db.AppDatabase.forTesting(
        NativeDatabase(
          File(path),
          setup: (raw) => raw.execute('PRAGMA query_only=ON'),
        ),
      );
      final service = ChannelInventorySyncService(
        database: database,
        fingerprintOverride: fingerprint,
      );
      addTearDown(() async {
        service.dispose();
        await database.close();
      });
      await service.sync();
      expect(
        service.state.value.error,
        isFalse,
        reason: service.state.value.phase,
      );
      expect(service.state.value.complete, isTrue);
      print(
        'Public route contribution completed: ${service.state.value.imported}',
      );
    },
    skip: path.isEmpty || fingerprint.isEmpty,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
