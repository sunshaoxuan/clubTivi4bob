import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/manual_channel_category.dart';
import 'package:clubtivi/features/channels/manual_category_move.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

db.Channel row(String id) => db.Channel(
  id: id,
  providerId: 'website',
  name: id,
  streamUrl: 'https://example.org/$id.m3u8',
  groupTitle: '中国 / 北京',
  streamType: 'live',
  sortOrder: 0,
  favorite: false,
  hidden: false,
);

void main() {
  final destination = ChannelCategoryDestination(['美国', '新闻']);
  test(
    'move updates only known routes immediately and preserves identifiers',
    () {
      final rows = [row('a'), row('b'), row('c')];
      final urls = {rows[0].streamUrl, rows[1].streamUrl};
      final moved = moveChannelRows(rows, urls, destination);
      expect(
        moved.take(2).every((item) => item.groupTitle == destination.group),
        isTrue,
      );
      expect(moved.map((item) => item.id), rows.map((item) => item.id));
      expect(
        moved.map((item) => item.streamUrl),
        rows.map((item) => item.streamUrl),
      );
      expect(identical(moved.last, rows.last), isTrue);
      expect(rows.first.groupTitle, '中国 / 北京');
      expect(
        canRetainRowsAfterManualCategoryChange(rows, moved, {
          for (final url in urls) url: destination,
        }),
        isTrue,
      );
    },
  );

  test('external category edits and other field changes still reload', () {
    final before = [row('a')];
    final manual = {before.first.streamUrl: destination};
    final moved = moveChannelRows(before, manual.keys.toSet(), destination);
    expect(
      canRetainRowsAfterManualCategoryChange(null, moved, manual),
      isFalse,
    );
    expect(canRetainRowsAfterManualCategoryChange(before, [], manual), isFalse);
    expect(
      canRetainRowsAfterManualCategoryChange(before, [
        ...moved,
        row('b'),
      ], manual),
      isFalse,
    );
    expect(
      canRetainRowsAfterManualCategoryChange(before, [
        moved.first.copyWith(name: 'new'),
      ], manual),
      isFalse,
    );
    expect(
      canRetainRowsAfterManualCategoryChange(before, [
        moved.first.copyWith(streamUrl: 'https://other.org/a'),
      ], manual),
      isFalse,
    );
    expect(
      canRetainRowsAfterManualCategoryChange(before, [
        before.first.copyWith(groupTitle: const Value('中国 / 湖南')),
      ], manual),
      isFalse,
    );
    expect(canRetainRowsAfterManualCategoryChange(before, moved, {}), isFalse);
  });

  test('intermediate queued save does not overwrite a later visible move', () {
    final before = [row('a')];
    final intermediate = moveChannelRows(before, {
      before.first.streamUrl,
    }, ChannelCategoryDestination(['美国', '体育']));
    final pending = {before.first.streamUrl};
    final latest = {before.first.streamUrl: destination};
    expect(
      canRetainRowsAfterManualCategoryChange(
        before,
        intermediate,
        latest,
        pendingUrls: pending,
      ),
      isTrue,
    );
    expect(
      canRetainRowsAfterManualCategoryChange(
        before,
        [intermediate.first.copyWith(name: 'external name')],
        latest,
        pendingUrls: pending,
      ),
      isFalse,
    );
  });

  test(
    'large catalog retains unchanged row objects and skips duplicate reload',
    () {
      final before = List.generate(30000, (index) => row('$index'));
      final urls = {before[14999].streamUrl};
      final moved = moveChannelRows(before, urls, destination);
      expect(moved.length, 30000);
      expect(identical(moved.first, before.first), isTrue);
      expect(identical(moved.last, before.last), isTrue);
      expect(
        canRetainRowsAfterManualCategoryChange(before, moved, {
          urls.single: destination,
        }),
        isTrue,
      );
      expect(canRetainRowsAfterManualCategoryChange(moved, moved, {}), isTrue);
    },
  );
}
