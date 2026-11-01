// Isolated, silent benchmark. Run against an SQLite backup, never the live DB.
import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/stream_alternatives_service.dart';
import 'package:clubtivi/data/services/stream_health_tracker.dart';
import 'package:clubtivi/data/services/category_load_cache.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('category database benchmark', () async {
    SharedPreferences.setMockInitialValues({});
    final path = Platform.environment['BOBTV_CATEGORY_BENCH_DB'];
    expect(path, isNotNull, reason: 'Supply an isolated SQLite backup');
    final database = db.AppDatabase.forTesting(NativeDatabase(File(path!)));
    addTearDown(database.close);
    final timings = <String, Object>{};
    Future<T> timed<T>(String label, Future<T> Function() work) async {
      final clock = Stopwatch()..start();
      final result = await work();
      timings[label] = clock.elapsedMicroseconds / 1000;
      return result;
    }

    if (Platform.environment['BOBTV_CATEGORY_BENCH_LEGACY'] == '1') {
      final channels = await timed(
        'internationalQueryMs',
        () => database.getChannelCategoryCandidates('国际'),
      );
      timings['materializedRows'] = channels.length;
      await timed(
        'presentationMs',
        () => database.channelPresentationKeys(channels),
      );
      await timed(
        'categoryMetadataMs',
        () => database.publicCatalogCategoryGroups(channels.map((c) => c.id)),
      );
      await timed(
        'mergeMetadataMs',
        () => database.channelMergeIds(channels.map((c) => c.streamUrl)),
      );
      final service = StreamAlternativesService(
        database,
        StreamHealthTracker(),
      );
      await timed('alternativesMs', () => service.rebuildForChannels(channels));
    } else {
      await timed(
        'storedFavoritesMs',
        () => database.getAllFavoritedChannelIds(reconcile: false),
      );
      await timed(
        'countryNavigationMs',
        () => database.getInternationalCountryCounts(publicOnly: true),
      );
      final cache =
          CategoryLoadCache<
            ({List<db.Channel> rows, ChannelIndexMetadata metadata})
          >();
      for (final country in ['马来西亚', '美国', '马来西亚']) {
        final snapshot = await timed(
          '${country}_${cache.contains(country) ? 'warm' : 'cold'}_listMs',
          () => cache.load(country, () async {
            final rows = await database.getChannelCategoryCandidates(
              '国际',
              internationalCountry: country,
              publicOnly: true,
            );
            final values = await Future.wait([
              database.channelPresentationKeys(rows),
              database.channelMergeIds(rows.map((c) => c.streamUrl)),
              database.publicCatalogChannelIds(rows.map((c) => c.id)),
            ]);
            await database.publicCatalogCategoryGroups(rows.map((c) => c.id));
            return (
              rows: rows,
              metadata: ChannelIndexMetadata(
                presentationKeys: values[0],
                mergeIds: values[1],
                catalogIds: values[2],
              ),
            );
          }),
        );
        timings['${country}_rows'] = snapshot.rows.length;
        await timed(
          '${country}_alternativesMs',
          () => StreamAlternativesService(
            database,
            StreamHealthTracker(),
          ).rebuildForChannels(snapshot.rows, metadata: snapshot.metadata),
        );
      }
      print('CATEGORY_INTERACTIVE ${jsonEncode(timings)}');
      await timed(
        'historicalFavoriteReconcileMs',
        () => database.reconcileFavoriteMemberships(),
      );
    }
    // Only aggregate counts and timings leave the fixture. No private rows/URLs.
    print('CATEGORY_BENCHMARK ${jsonEncode(timings)}');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
