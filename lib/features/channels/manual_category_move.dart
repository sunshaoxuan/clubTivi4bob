import 'package:drift/drift.dart' show Value;

import '../../data/datasources/local/database.dart' as db;
import '../../data/services/manual_channel_category.dart';

/// Update existing rows without reloading route checks or playback state.
List<db.Channel> moveChannelRows(
  List<db.Channel> rows,
  Set<String> urls,
  ChannelCategoryDestination destination,
) => [
  for (final row in rows)
    urls.contains(row.streamUrl)
        ? row.copyWith(groupTitle: Value(destination.group))
        : row,
];

/// Database notifications for a locally applied category edit need no reload.
/// Every other field, insertion, deletion and external edit still reloads.
bool canRetainRowsAfterManualCategoryChange(
  List<db.Channel>? previous,
  List<db.Channel> next,
  Map<String, ChannelCategoryDestination> manual, {
  Set<String> pendingUrls = const {},
}) {
  if (previous == null || previous.length != next.length) return false;
  for (var index = 0; index < next.length; index++) {
    final before = previous[index];
    final after = next[index];
    if (before == after) continue;
    final destination = manual[after.streamUrl];
    if ((!pendingUrls.contains(after.streamUrl) &&
            (destination == null || after.groupTitle != destination.group)) ||
        before.copyWith(groupTitle: Value(after.groupTitle)) != after) {
      return false;
    }
  }
  return true;
}
