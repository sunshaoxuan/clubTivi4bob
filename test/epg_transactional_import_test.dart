import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/datasources/parsers/xmltv_parser.dart';
import 'package:clubtivi/data/models/epg.dart';
import 'package:clubtivi/data/services/epg_refresh_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late EpgRefreshService service;
  final now = DateTime.utc(2026, 10, 16, 0);

  XmltvResult guide(String source, String title, {bool expired = false}) =>
      XmltvResult(
        channels: [
          EpgChannel(id: 'exact', sourceId: source, displayNames: [title]),
        ],
        programmes: [
          EpgProgramme(
            channelId: 'exact',
            sourceId: source,
            start: now.subtract(const Duration(hours: 1)),
            stop: expired
                ? now.subtract(const Duration(minutes: 1))
                : now.add(const Duration(hours: 1)),
            title: title,
          ),
        ],
      );

  setUp(() async {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    service = EpgRefreshService(database);
    for (final id in ['shared', 'private']) {
      await database.upsertEpgSource(
        db.EpgSourcesCompanion.insert(
          id: id,
          name: id,
          url: 'https://example.org/$id.xml',
        ),
      );
    }
    await service.importParsed('shared', guide('shared', 'Old'), at: now);
    await service.importParsed(
      'private',
      guide('private', 'Private guide'),
      at: now,
    );
  });
  tearDown(() => database.close());

  Future<List<String>> titles() async =>
      (await database.select(database.epgProgrammes).get())
          .map((p) => p.title)
          .toList()
        ..sort();

  test('two consecutive imports replace only their own source', () async {
    await service.importParsed(
      'shared',
      guide('shared', 'Version two'),
      at: now,
    );
    expect(await titles(), ['Private guide', 'Version two']);
    await service.importParsed(
      'shared',
      guide('shared', 'Version three'),
      at: now,
    );
    expect(await titles(), ['Private guide', 'Version three']);
    expect(
      (await database.getEpgChannelsForSource('shared')).single.displayName,
      'Version three',
    );
  });

  test('empty and expired-only imports preserve last valid guide', () async {
    await expectLater(
      service.importParsed(
        'shared',
        XmltvResult(channels: [], programmes: []),
        at: now,
      ),
      throwsFormatException,
    );
    await expectLater(
      service.importParsed(
        'shared',
        guide('shared', 'Expired', expired: true),
        at: now,
      ),
      throwsFormatException,
    );
    expect(await titles(), ['Old', 'Private guide']);
  });

  test(
    'cross-source data and unknown channels cannot replace a source',
    () async {
      await expectLater(
        service.importParsed(
          'shared',
          guide('private', 'Wrong source'),
          at: now,
        ),
        throwsFormatException,
      );
      final invalid = guide('shared', 'Wrong channel');
      await expectLater(
        service.importParsed(
          'shared',
          XmltvResult(channels: [], programmes: invalid.programmes),
          at: now,
        ),
        throwsFormatException,
      );
      expect(await titles(), ['Old', 'Private guide']);
    },
  );

  test(
    'database insertion failure rolls back programmes metadata and refresh time',
    () async {
      final before = (await database.getAllEpgSources())
          .firstWhere((s) => s.id == 'shared')
          .lastRefresh;
      await database.customStatement(
        "CREATE TRIGGER reject_bad BEFORE INSERT ON epg_programmes WHEN NEW.title='Reject' BEGIN SELECT RAISE(ABORT,'rejected'); END",
      );
      await expectLater(
        service.importParsed('shared', guide('shared', 'Reject'), at: now),
        throwsA(anything),
      );
      expect(await titles(), ['Old', 'Private guide']);
      expect(
        (await database.getEpgChannelsForSource('shared')).single.displayName,
        'Old',
      );
      expect(
        (await database.getAllEpgSources())
            .firstWhere((s) => s.id == 'shared')
            .lastRefresh,
        before,
      );
    },
  );
}
