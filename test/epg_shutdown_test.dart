import 'dart:async';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/datasources/parsers/xmltv_parser.dart';
import 'package:clubtivi/data/services/epg_refresh_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class PausedDatabase extends db.AppDatabase {
  PausedDatabase() : super.forTesting(NativeDatabase.memory());
  final writing = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> updateEpgSourceRefreshTime(String id) async {
    writing.complete();
    await release.future;
    await super.updateEpgSourceRefreshTime(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('EPG shutdown joins in-flight atomic import and prevents later DB work', () async {
    final database = PausedDatabase();
    final service = EpgRefreshService(database);
    await database.upsertEpgSource(db.EpgSourcesCompanion.insert(
      id: 's', name: 'S', url: 'https://example.org/epg'));
    final result = XmltvParser().parse('''<tv>
      <channel id="c"><display-name>C</display-name></channel>
      <programme channel="c" start="20300101000000 +0000" stop="20300101010000 +0000"><title>Valid</title></programme>
    </tv>''', sourceId: 's');
    final import = service.importParsed('s', result, at: DateTime.utc(2030));
    await database.writing.future;
    var stopped = false;
    final shutdown = service.shutdown().then((_) => stopped = true);
    await Future<void>.delayed(Duration.zero);
    expect(stopped, false);
    database.release.complete();
    await import;
    await shutdown;
    expect((await database.select(database.epgProgrammes).get()).length, 1);
    await database.close();
    // Closed database access would throw if any of these entered the DB again.
    await service.refreshAllSources(force: true);
    await service.refreshSource('s');
    await service.importParsed('s', result);
    await service.addDefaultSources();
    await service.shutdown();
  });
}
