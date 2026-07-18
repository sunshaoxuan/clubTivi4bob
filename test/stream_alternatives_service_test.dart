import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/stream_alternatives_service.dart';
import 'package:clubtivi/data/services/stream_health_tracker.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late db.AppDatabase database;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  test(
    'keeps a mislabeled CCTV5 Plus route out of CCTV5 alternatives',
    () async {
      await database.upsertProvider(
        db.ProvidersCompanion.insert(
          id: 'source',
          name: 'Test source',
          type: 'm3u',
        ),
      );
      await database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'cctv5-main',
          providerId: 'source',
          name: 'CCTV-5',
          tvgName: const Value('CCTV5'),
          streamUrl: 'https://example.com/cctv5-main.m3u8',
        ),
        db.ChannelsCompanion.insert(
          id: 'cctv5-alt',
          providerId: 'source',
          name: 'CCTV5 体育',
          streamUrl: 'https://example.com/cctv5-alt.m3u8',
        ),
        db.ChannelsCompanion.insert(
          id: 'cctv5plus-bad-metadata',
          providerId: 'source',
          name: 'CCTV-5+',
          tvgName: const Value('CCTV5[720][S]'),
          streamUrl: 'https://example.com/cctv5plus.m3u8',
        ),
        db.ChannelsCompanion.insert(
          id: 'cctv5-4k-main',
          providerId: 'source',
          name: 'CCTV5 4K',
          streamUrl: 'https://example.com/cctv5-4k-main.m3u8',
        ),
        db.ChannelsCompanion.insert(
          id: 'cctv5-4k-alt',
          providerId: 'source',
          name: 'CCTV5 UHD',
          streamUrl: 'https://example.com/cctv5-4k-alt.m3u8',
        ),
      ]);

      final service = StreamAlternativesService(
        database,
        StreamHealthTracker(),
      );
      await service.rebuild();

      final alternatives = service.getAlternatives(
        channelId: 'cctv5-main',
        channelName: 'CCTV-5',
        originalName: 'CCTV-5',
        excludeUrl: 'https://example.com/cctv5-main.m3u8',
      );
      final details = service.getAlternativeDetails(
        channelId: 'cctv5-main',
        channelName: 'CCTV-5',
        originalName: 'CCTV-5',
        excludeUrl: 'https://example.com/cctv5-main.m3u8',
      );

      expect(alternatives, contains('https://example.com/cctv5-alt.m3u8'));
      expect(
        alternatives,
        isNot(contains('https://example.com/cctv5plus.m3u8')),
      );
      expect(
        details.map((detail) => detail.channel.streamUrl),
        isNot(contains('https://example.com/cctv5plus.m3u8')),
      );

      final ultraHdAlternatives = service.getAlternatives(
        channelId: 'cctv5-4k-main',
        channelName: 'CCTV5 4K',
        originalName: 'CCTV5 4K',
        excludeUrl: 'https://example.com/cctv5-4k-main.m3u8',
      );
      expect(
        ultraHdAlternatives,
        contains('https://example.com/cctv5-4k-alt.m3u8'),
      );
      expect(
        ultraHdAlternatives,
        isNot(contains('https://example.com/cctv5-alt.m3u8')),
      );
    },
  );
}
