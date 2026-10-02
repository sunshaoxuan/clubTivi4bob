import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  final now = DateTime.utc(2026, 10, 3, 12);

  setUp(() async {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await database.upsertEpgSource(
      db.EpgSourcesCompanion.insert(
        id: 'guide',
        name: 'Guide',
        url: 'https://example.com/guide.xml',
      ),
    );
  });
  tearDown(() => database.close());

  db.EpgProgrammesCompanion programme(
    String channel,
    String title,
    DateTime start,
    DateTime stop,
  ) => db.EpgProgrammesCompanion.insert(
    epgChannelId: channel,
    sourceId: 'guide',
    title: title,
    start: start,
    stop: stop,
  );

  test(
    'includes a long current film and returns only the exact channel',
    () async {
      await database.insertProgrammes([
        programme(
          'CCTV6',
          'Later',
          now.add(const Duration(hours: 1)),
          now.add(const Duration(hours: 2)),
        ),
        programme(
          'CCTV1',
          'Other channel',
          now.subtract(const Duration(minutes: 30)),
          now.add(const Duration(minutes: 30)),
        ),
        programme(
          'CCTV6',
          'Long film',
          now.subtract(const Duration(hours: 3)),
          now.add(const Duration(minutes: 30)),
        ),
        programme(
          'CCTV6',
          'Just ended',
          now.subtract(const Duration(hours: 4)),
          now,
        ),
        programme(
          'CCTV6',
          'Next',
          now.add(const Duration(minutes: 30)),
          now.add(const Duration(hours: 1)),
        ),
        programme(
          'CCTV6',
          'Fourth',
          now.add(const Duration(hours: 2)),
          now.add(const Duration(hours: 3)),
        ),
      ]);

      final rows = await database.getUpcomingProgrammes(
        epgChannelId: 'CCTV6',
        at: now,
      );
      expect(rows.map((row) => row.title), ['Long film', 'Next', 'Later']);
    },
  );

  test(
    'bounds the requested result count and handles unknown EPG IDs',
    () async {
      await database.insertProgrammes([
        for (var index = 0; index < 30; index++)
          programme(
            'CCTV6',
            'Programme $index',
            now.add(Duration(hours: index)),
            now.add(Duration(hours: index + 1)),
          ),
      ]);
      expect(
        await database.getUpcomingProgrammes(
          epgChannelId: 'CCTV6',
          at: now,
          limit: 1000,
        ),
        hasLength(20),
      );
      expect(
        await database.getUpcomingProgrammes(
          epgChannelId: 'CCTV6',
          at: now,
          limit: 0,
        ),
        isEmpty,
      );
      expect(
        await database.getUpcomingProgrammes(epgChannelId: 'missing', at: now),
        isEmpty,
      );
    },
  );
  test(
    'overlapping current rows leave space for upcoming programmes',
    () async {
      await database.insertProgrammes([
        for (var index = 1; index <= 4; index++)
          programme(
            'CCTV6',
            'Current from $index hours ago',
            now.subtract(Duration(hours: index)),
            now.add(const Duration(minutes: 30)),
          ),
        programme(
          'CCTV6',
          'Next film',
          now.add(const Duration(minutes: 30)),
          now.add(const Duration(hours: 2)),
        ),
        programme(
          'CCTV6',
          'Evening film',
          now.add(const Duration(hours: 2)),
          now.add(const Duration(hours: 4)),
        ),
      ]);

      final rows = await database.getUpcomingProgrammes(
        epgChannelId: 'CCTV6',
        at: now,
      );
      expect(rows.map((row) => row.title), [
        'Current from 1 hours ago',
        'Next film',
        'Evening film',
      ]);
      final one = await database.getUpcomingProgrammes(
        epgChannelId: 'CCTV6',
        at: now,
        limit: 1,
      );
      expect(one.single.title, 'Current from 1 hours ago');
    },
  );

  test('a gap in the guide returns three future entries', () async {
    await database.insertProgrammes([
      for (var index = 1; index <= 3; index++)
        programme(
          'CCTV6',
          'Future $index',
          now.add(Duration(hours: index)),
          now.add(Duration(hours: index + 1)),
        ),
    ]);
    final rows = await database.getUpcomingProgrammes(
      epgChannelId: 'CCTV6',
      at: now,
    );
    expect(rows.map((row) => row.title), ['Future 1', 'Future 2', 'Future 3']);
  });
}
