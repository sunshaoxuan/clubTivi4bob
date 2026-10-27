import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:clubtivi/data/services/manual_channel_category.dart';
import 'package:clubtivi/data/services/channel_category_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'confirmed regions collapse genre tails without changing stored groups',
    () {
      final groups = [
        '中国 / 上海 / 财经',
        '中国 / 上海 / 新闻',
        '中国 / 云南 / 新闻',
        '中国 / 北京 / 儿童',
      ];
      final destinations = groups
          .map(ChannelCategoryDestination.fromGroup)
          .cast<ChannelCategoryDestination>()
          .toList();
      expect(destinations.map((d) => d.group), groups);
      expect(destinations.map((d) => d.category), ['上海', '上海', '云南', '北京']);
      final navigation = ChannelCategoryDestination.navigationCategories(
        destinations,
      );
      expect(
        navigation.where(
          (s) =>
              s.contains(' / 财经') || s.contains(' / 新闻') || s.contains(' / 儿童'),
        ),
        isEmpty,
      );
      for (final region in ['上海', '云南', '北京']) {
        expect(navigation.where((s) => s == region).length, 1);
        expect(ChannelCategoryClassifier.provinceCategories, contains(region));
      }
      expect(
        ChannelCategoryDestination.fromGroup('中国 / 地方 / 新地区 / 新闻')!.category,
        '地方 / 新地区 / 新闻',
      );
    },
  );
  test(
    'region query retains all genre subgroups and rejects other regions',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.upsertProvider(
        db.ProvidersCompanion.insert(
          id: 'bobtv-channel-catalog',
          name: 'Test',
          type: 'catalog',
        ),
      );
      for (final entry in {
        'finance': '中国 / 上海 / 财经',
        'news': '中国 / 上海 / 新闻',
        'beijing': '中国 / 北京 / 儿童',
      }.entries) {
        await database.upsertChannels([
          db.ChannelsCompanion.insert(
            id: entry.key,
            providerId: 'bobtv-channel-catalog',
            name: 'Station ${entry.key}',
            streamUrl: 'https://example.org/${entry.key}.m3u8',
            groupTitle: Value(entry.value),
          ),
        ]);
      }
      final candidates = await database.getChannelCategoryCandidates('上海');
      final visible = candidates.where(
        (channel) =>
            ChannelCategoryDestination.fromGroup(
              channel.groupTitle,
            )?.category ==
            '上海',
      );
      expect(
        visible.map((channel) => channel.id),
        unorderedEquals(['finance', 'news']),
      );
      final stored = await database.getStructuredCategoryGroups();
      expect(
        stored,
        containsAll(['中国 / 上海 / 财经', '中国 / 上海 / 新闻', '中国 / 北京 / 儿童']),
      );
    },
  );
}
