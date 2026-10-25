import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/epg_refresh_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'startup preserves custom global, old default and disabled EPG sources',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      for (final (id, url, enabled) in [
        ('global', 'https://example.org/global.xml', true),
        (
          'old',
          'https://raw.githubusercontent.com/usa-local-epg/usa-locals/main/usalocals.xml.gz',
          true,
        ),
        ('off', 'http://epg.best/16b5b-ypkixv.xml.gz', false),
      ]) {
        await database.upsertEpgSource(
          db.EpgSourcesCompanion.insert(
            id: id,
            name: id,
            url: url,
            enabled: Value(enabled),
            refreshIntervalHours: const Value(12),
          ),
        );
      }
      final service = EpgRefreshService(database);
      await service.addDefaultSources();
      await service.addDefaultSources();
      final sources = await database.getAllEpgSources();
      expect(sources.map((s) => s.id).toSet(), {'global', 'old', 'off'});
      expect(sources.singleWhere((s) => s.id == 'off').enabled, false);
      expect(sources.every((s) => s.refreshIntervalHours == 12), true);
      await service.shutdown();
    },
  );
}
