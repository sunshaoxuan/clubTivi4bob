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
    expect(ChannelCategoryDestination(['中国', '地方', '新地区']).valid, isTrue);
    expect(ChannelCategoryDestination(['美国', '新闻', '财经']).valid, isTrue);
  });

  test(
    'explicit new countries and nested categories round trip without guessing',
    () {
      for (final path in [
        ['科威特', '生活', '饮食', '烘焙'],
        ['中国', '地方', '陕西', '西安'],
        ['中国', '文化', '戏曲'],
        ['中国', '地方', '新地区', '城区'],
      ]) {
        final destination = ChannelCategoryDestination(path);
        expect(destination.valid, isTrue);
        final restored = ChannelCategoryDestination.fromGroup(
          destination.group,
        )!;
        expect(restored.group, destination.group);
        expect(restored.category, destination.category);
        expect(restored.country, destination.country);
      }
      expect(ChannelCategoryDestination(['科威特']).valid, isTrue);
      expect(ChannelCategoryDestination.fromGroup('中国 / 央视')!.path, [
        '中国',
        '央视',
      ]);
      expect(ChannelCategoryDestination.fromGroup('中国 / 北京')!.path, [
        '中国',
        '地方',
        '北京',
      ]);
      expect(ChannelCategoryDestination.fromGroup('原始订阅分类'), isNull);
      expect(ChannelCategoryDestination.fromGroup('国际 / 中国'), isNull);
    },
  );

  test(
    'invalid separators, reserved labels, excessive length and depth are rejected',
    () {
      for (final name in [
        '',
        '  ',
        'A / B',
        r'A\B',
        'A\nB',
        'A\u200bB',
        '全部',
        'Favorites',
        'fav:test',
        '字' * 49,
      ]) {
        expect(
          ChannelCategoryDestination(['科威特', name]).valid,
          isFalse,
          reason: name,
        );
      }
      expect(ChannelCategoryDestination(['国际']).valid, isFalse);
      expect(ChannelCategoryDestination(['中国', '国际']).valid, isFalse);
      expect(
        ChannelCategoryDestination(List.generate(7, (i) => '分类$i')).valid,
        isFalse,
      );
      expect(
        ChannelCategoryDestination(List.filled(6, '字' * 48)).valid,
        isFalse,
      );
      expect(ChannelCategoryDestination([' 科威特 ', ' 自然  科学 ']).path, [
        '科威特',
        '自然 科学',
      ]);
    },
  );

  test(
    'suggestions and navigation include saved custom paths without duplicates',
    () {
      final saved = [
        ChannelCategoryDestination(['科威特', '自然科学', '生态']),
        ChannelCategoryDestination(['中国', '文化', '戏曲']),
        ChannelCategoryDestination(['中国', '文化', '戏曲']),
      ];
      expect(
        ChannelCategoryDestination.children(
          [],
          existing: saved,
        ).where((name) => name == '科威特'),
        hasLength(1),
      );
      expect(
        ChannelCategoryDestination.children(['科威特'], existing: saved),
        contains('自然科学'),
      );
      expect(
        ChannelCategoryDestination.children(['中国', '文化'], existing: saved),
        ['戏曲'],
      );
      final navigation = ChannelCategoryDestination.navigationCategories(saved);
      expect(navigation.where((name) => name == '文化 / 戏曲'), hasLength(1));
      expect(navigation, contains('央视'));
    },
  );

  test(
    'custom paths persist and query exact membership independently of names',
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
      await database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'chosen',
          providerId: 'bobtv-channel-catalog',
          name: 'CCTV-1',
          streamUrl: 'https://example.org/chosen.m3u8',
        ),
        db.ChannelsCompanion.insert(
          id: 'other',
          providerId: 'bobtv-channel-catalog',
          name: '文化戏曲',
          streamUrl: 'https://example.org/other.m3u8',
        ),
      ]);
      final destination = ChannelCategoryDestination(['中国', '文化', '戏曲']);
      await database.setManualChannelCategory([
        'https://example.org/chosen.m3u8',
      ], destination);
      expect(
        (await ManualChannelCategory.load()).values.single.path,
        destination.path,
      );
      expect(
        (await database.getChannelCategoryCandidates(
          destination.category,
        )).map((c) => c.id),
        ['chosen'],
      );
      expect(await database.getStructuredCategoryGroups(), [destination.group]);
      expect(
        ((await database.pendingSharedEvents())
                .where((e) => e['kind'] == 'classify')
                .single['payload']
            as Map)['group'],
        destination.group,
      );
    },
  );

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
