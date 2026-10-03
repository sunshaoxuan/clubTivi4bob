import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/manual_channel_category.dart';
import 'package:clubtivi/features/channels/channel_category_picker.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('destinations validate every level and retain country and genre', () {
    expect(ChannelCategoryDestination(['中国']).valid, isFalse);
    expect(ChannelCategoryDestination(['中国', '地方']).valid, isFalse);
    final province = ChannelCategoryDestination(['中国', '地方', '北京']);
    expect(province.valid, isTrue);
    expect(province.group, '中国 / 北京');
    expect(province.category, '北京');
    final news = ChannelCategoryDestination(['美国', '新闻']);
    expect(news.valid, isTrue);
    expect(news.group, '国际 / 美国 / 新闻');
    expect(news.category, '国际');
    expect(news.country, '美国');
    expect(ChannelCategoryDestination(['美国']).valid, isTrue);
    expect(ChannelCategoryDestination(['中国', '地方', '美国']).valid, isFalse);
    expect(ChannelCategoryDestination(['美国', '新闻', '北京']).valid, isFalse);
  });

  test(
    'route corrections survive name, ID and provider refresh changes',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.upsertProvider(
        db.ProvidersCompanion.insert(id: 'test', name: 'Test', type: 'm3u'),
      );
      db.ChannelsCompanion entry(String id, String url) =>
          db.ChannelsCompanion.insert(
            id: id,
            providerId: 'test',
            name: 'NRBTV',
            streamUrl: url,
          );
      await database.upsertChannels([
        entry('a', 'https://example.org/a.m3u8'),
        entry('b', 'https://example.org/b.m3u8'),
        entry('other', 'https://example.org/other.m3u8'),
      ]);
      final destination = ChannelCategoryDestination(['美国', '宗教']);
      await database.setManualChannelCategory([
        'https://example.org/a.m3u8',
        'https://example.org/b.m3u8',
      ], destination);
      final saved = await ManualChannelCategory.load();
      expect(saved.length, 2);
      expect(saved['https://example.org/a.m3u8']!.group, '国际 / 美国 / 宗教');
      await database.upsertChannels([
        entry('refreshed-id', 'https://example.org/a.m3u8'),
      ]);
      final routes = await database.getChannelsByStreamUrls([
        'https://example.org/a.m3u8',
      ]);
      expect(routes, hasLength(2));
      expect(
        routes.every((route) => route.groupTitle == destination.group),
        isTrue,
      );
      final untouched = await database.getChannelsByStreamUrls([
        'https://example.org/other.m3u8',
      ]);
      expect(untouched.single.groupTitle, isNull);
    },
  );

  test('a later manual change replaces earlier destination', () async {
    await ManualChannelCategory.save([
      'url',
    ], ChannelCategoryDestination(['美国', '新闻']));
    await ManualChannelCategory.save([
      'url',
    ], ChannelCategoryDestination(['中国', '地方', '湖南']));
    expect((await ManualChannelCategory.load())['url']!.category, '湖南');
  });

  testWidgets('picker drills into provinces and lets the user go back', (
    tester,
  ) async {
    ChannelCategoryDestination? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                selected = await showDialog<ChannelCategoryDestination>(
                  context: context,
                  builder: (_) =>
                      const ChannelCategoryPicker(channelName: 'NRBTV'),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('中国'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('地方'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('北京'));
    await tester.pumpAndSettle();
    expect(find.text('中国 / 地方 / 北京'), findsOneWidget);
    await tester.tap(find.text('地方'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('天津'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用分类'));
    await tester.pumpAndSettle();
    expect(selected!.path, ['中国', '地方', '天津']);
    expect(tester.takeException(), isNull);
  });
}
