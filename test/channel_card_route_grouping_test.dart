import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_merge.dart';
import 'package:clubtivi/data/services/channel_presentation_identity.dart';
import 'package:clubtivi/data/services/stream_alternatives_service.dart';
import 'package:clubtivi/data/services/stream_health_tracker.dart';
import 'package:clubtivi/features/channels/channel_merge_dialog.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const provider = 'bobtv-channel-catalog';
const domestic = '中国 / 数字';
const international = '国际 / 美国 / 新闻';

ChannelPresentationRoute publicRoute(
  String id, {
  String name = '风云剧场',
  String group = domestic,
  String? epg,
  String? catalogId,
  String? countryCode,
  String? regionCode,
}) => ChannelPresentationRoute(
  id: id,
  name: name,
  group: group,
  tvgId: epg,
  catalogId: catalogId ?? id,
  countryCode: countryCode,
  regionCode: regionCode,
  url: 'https://media.example.org/$id',
);

Future<void> seed(db.AppDatabase database, {String group = domestic}) async {
  await database.withoutSharedReporting(() async {
    await database.upsertProvider(
      db.ProvidersCompanion.insert(
        id: provider,
        name: 'Shared',
        type: 'catalog',
      ),
    );
    await database.upsertChannels([
      for (final entry in {
        'one': 'https://MEDIA.example.org:443/a',
        'two': 'https://media.example.org/b',
        'duplicate': 'https://media.example.org/a',
      }.entries)
        db.ChannelsCompanion.insert(
          id: entry.key,
          providerId: provider,
          name: '风云剧场',
          tvgId: Value(group == international ? 'guide-${entry.key}' : null),
          groupTitle: Value(group),
          streamUrl: entry.value,
        ),
    ]);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'domestic public IDs share one service and preserve version boundaries',
    () {
      final keys = ChannelPresentationIdentity.keys([
        publicRoute('one'),
        publicRoute('two'),
        publicRoute('uhd', name: '风云剧场 4K'),
        publicRoute('delay', name: '风云剧场 +1'),
        publicRoute('radio', group: '中国 / 广播'),
        publicRoute('region', group: '中国 / 北京'),
        publicRoute('guide', epg: 'other-service'),
        publicRoute('unknown', group: '中国 / 未识别地区'),
      ]);
      expect(keys['one'], keys['two']);
      expect(keys.values.toSet(), hasLength(7));
    },
  );

  test(
    'explicit country and region conflicts keep same-name public IDs separate',
    () {
      final keys = ChannelPresentationIdentity.keys([
        publicRoute('one', countryCode: 'cn', regionCode: 'north'),
        publicRoute('two', countryCode: 'cn', regionCode: 'south'),
        publicRoute('other-country', countryCode: 'sg', regionCode: 'north'),
        publicRoute('missing'),
      ]);
      expect(keys.values.toSet(), hasLength(4));
    },
  );

  test(
    'one authoritative catalog identity survives inconsistent route labels',
    () {
      final keys = ChannelPresentationIdentity.keys([
        publicRoute('one', catalogId: 'shared'),
        publicRoute('two', catalogId: 'shared', name: '风云剧场 4K'),
      ]);
      expect(keys.values.toSet(), {'catalog:shared'});
    },
  );

  test(
    'one card, two canonical routes, favorites and playback use same identity',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await seed(database);
      final channels = await database.getAllChannels();
      final keys = await database.channelPresentationKeys(channels);
      final cards = ChannelPresentationIdentity.representatives(
        channels,
        idOf: (c) => c.id,
        keyOf: (c) => keys[c.id]!,
        scoreOf: (_) => 0,
        playingId: 'one',
      );
      expect(cards.single.id, 'one');
      final choice = (await database.searchChannelMergeChoices(
        query: '风云剧场',
      )).single;
      expect(choice.routeCount, 2);
      expect(await database.channelsForMergeChoice(choice), hasLength(3));
      await database.addChannelToDefaultFavorites('one');
      expect(await database.getAllFavoritedChannelIds(), {
        'one',
        'two',
        'duplicate',
      });
      final alternatives = StreamAlternativesService(
        database,
        StreamHealthTracker(),
      );
      await alternatives.rebuild();
      expect(
        alternatives.getAlternatives(
          channelId: 'one',
          excludeUrl: 'https://MEDIA.example.org:443/a',
        ),
        ['https://media.example.org/b'],
      );
      expect(
        alternatives
            .getAlternativeDetails(
              channelId: 'one',
              excludeUrl: 'https://media.example.org/a',
            )
            .map((d) => d.channel.id),
        ['two'],
      );
      expect(await database.getAllChannels(), hasLength(3));
      expect(await database.getAllMappings(), isEmpty);
      expect(await database.pendingSharedEvents(), isEmpty);
    },
  );

  test(
    'same-name choices stay distinct and selected members never expand by name',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await seed(database, group: international);
      final choices = await database.searchChannelMergeChoices(query: '风云剧场');
      expect(choices, hasLength(3));
      for (final choice in choices) {
        expect(
          (await database.channelsForMergeChoice(choice)).single.id,
          choice.id,
        );
      }
      final channel = (await database.getChannelsByIds({'one'})).single;
      final selected = await database.channelMergeChoiceForChannel(channel);
      expect(selected.id, 'one');
      await database.mergeChannels(
        ChannelMergePlan(
          name: 'Unified',
          group: international,
          urls: [channel.streamUrl, 'https://media.example.org/b'],
        ),
      );
      await expectLater(
        database.channelsForMergeChoice(selected),
        throwsStateError,
      );
    },
  );

  test(
    'old domestic categories and self-name guide IDs identify one national service',
    () {
      final keys = ChannelPresentationIdentity.keys([
        publicRoute('one', group: '数字'),
        publicRoute('two', group: '中国 / 央视', epg: '风云剧场'),
        publicRoute('three', group: '中国 / 数字'),
      ]);
      expect(keys.values.toSet(), hasLength(1));
    },
  );

  test(
    'international genres share one service while countries and guides stay distinct',
    () {
      final keys = ChannelPresentationIdentity.keys([
        publicRoute('news', name: '凤凰中文', group: '国际 / 香港 / 新闻'),
        publicRoute(
          'general',
          name: '凤凰中文',
          group: '国际 / 香港 / 综合',
          epg: '凤凰中文',
          countryCode: 'hk',
        ),
        publicRoute('other-country', name: '凤凰中文', group: '国际 / 台湾 / 综合'),
        publicRoute(
          'other-guide',
          name: '凤凰中文',
          group: '国际 / 香港 / 新闻',
          epg: 'regional-service',
        ),
      ]);
      expect(keys['news'], keys['general']);
      expect(keys.values.toSet(), hasLength(3));
    },
  );

  test('national genre memberships share a service across root categories', () {
    final keys = ChannelPresentationIdentity.keys([
      for (final root in ['央视', '数字', '卫视'])
        for (final genre in [
          '',
          ...[
            '综合',
            '新闻',
            '体育',
            '电影',
            '剧集',
            '娱乐',
            '儿童',
            '纪录片',
            '音乐',
            '宗教',
            '公共事务',
          ],
        ])
          publicRoute(
            '$root/$genre',
            name: '第一剧场',
            group: '中国 / $root${genre.isEmpty ? '' : ' / $genre'}',
          ),
      publicRoute('custom', name: '第一剧场', group: '中国 / 央视 / 自定义'),
      publicRoute('nested', name: '第一剧场', group: '中国 / 央视 / 剧集 / 地方版'),
      publicRoute('local', name: '第一剧场', group: '中国 / 北京 / 剧集'),
      publicRoute('radio', name: '第一剧场', group: '中国 / 广播 / 剧集'),
      publicRoute(
        'guide',
        name: '第一剧场',
        group: '中国 / 数字 / 剧集',
        epg: 'different-service',
      ),
      publicRoute('uhd', name: '第一剧场 4K', group: '中国 / 数字 / 剧集'),
      publicRoute(
        'region',
        name: '第一剧场',
        group: '中国 / 数字 / 剧集',
        regionCode: 'north',
      ),
      publicRoute(
        'country',
        name: '第一剧场',
        group: '中国 / 数字 / 剧集',
        countryCode: 'sg',
      ),
    ]);
    expect(keys.values.take(36).toSet(), hasLength(1));
    expect(keys.values.toSet(), hasLength(9));
  });

  for (final anchorId in ['root', 'genre', 'old']) {
    test(
      'favorite from $anchorId groups national root and genre routes on reload',
      () async {
        final database = db.AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        await seed(database);
        await database.withoutSharedReporting(() async {
          await database.upsertProvider(
            db.ProvidersCompanion.insert(
              id: 'legacy',
              name: 'Legacy',
              type: 'm3u',
            ),
          );
          await database.upsertChannels([
            for (final entry in {
              'root': '中国 / 央视',
              'genre': '中国 / 数字 / 剧集',
              'genre-copy': '中国 / 央视 / 剧集',
              'old': '中国 / 央视 / 剧集',
            }.entries)
              db.ChannelsCompanion.insert(
                id: entry.key,
                providerId: entry.key == 'old' ? 'legacy' : provider,
                name: '第一剧场',
                groupTitle: Value(entry.value),
                streamUrl:
                    'https://media.example.org/${entry.key == 'genre-copy' ? 'root' : entry.key}',
              ),
          ]);
        });
        // Existing favorites written by earlier versions must reconcile too.
        final list = await database.createFavoriteList('Regression');
        await database.customStatement(
          'INSERT INTO favorite_list_channels(list_id,channel_id,sort_order) VALUES(?,?,0)',
          [list.id, anchorId],
        );
        await database.reconcileFavoriteMemberships(force: true);
        expect(await database.getAllFavoritedChannelIds(), {
          'root',
          'genre',
          'genre-copy',
          'old',
        });
        final rows = await database.getChannelsInList(list.id);
        final keys = await database.channelPresentationKeys(rows);
        expect(
          ChannelPresentationIdentity.representatives(
            rows,
            idOf: (c) => c.id,
            keyOf: (c) => keys[c.id]!,
            scoreOf: (_) => 0,
          ),
          hasLength(1),
        );
        final choice = (await database.searchChannelMergeChoices(
          query: '第一剧场',
        )).single;
        expect(choice.routeCount, 3);
        await database.removeChannelFromList(
          list.id,
          anchorId == 'root' ? 'genre' : 'root',
        );
        expect(await database.getAllFavoritedChannelIds(), isEmpty);
        await database.addChannelToList(list.id, anchorId);
        expect(await database.getAllFavoritedChannelIds(), {
          'root',
          'genre',
          'genre-copy',
          'old',
        });
        expect((await database.getAllChannels()).length, 7);
      },
    );
  }

  test('catalog identity is stable in category and favorite subsets', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await seed(database);
    await database.withoutSharedReporting(() async {
      await database.upsertChannels([
        db.ChannelsCompanion.insert(id: 'standard', providerId: provider,
          name: '第一剧场', groupTitle: const Value('中国 / 央视'),
          streamUrl: 'https://media.example.org/standard'),
        db.ChannelsCompanion.insert(id: 'inconsistent', providerId: provider,
          name: '第一剧场 4K', groupTitle: const Value('中国 / 数字 / 剧集'),
          streamUrl: 'https://media.example.org/inconsistent'),
      ]);
      for (final id in ['standard', 'inconsistent']) {
        await database.customStatement('INSERT INTO catalog_epg_routes VALUES(?,?,?,?,?,?)',
          [id, 'authoritative-theater', 'hash', '第一剧场', null, '中国 / 央视']);
      }
    });
    final all = await database.getChannelsByIds({'standard', 'inconsistent'});
    final full = await database.channelPresentationKeys(all);
    expect(full.values.toSet(), {'catalog:authoritative-theater'});
    for (final row in all) {
      expect((await database.channelPresentationKeys([row]))[row.id], full[row.id]);
    }
    await database.addChannelToDefaultFavorites('standard');
    expect(await database.getAllFavoritedChannelIds(), {'standard', 'inconsistent'});
    await database.removeChannelFromList('default', 'inconsistent');
    expect(await database.getAllFavoritedChannelIds(), isEmpty);
  });

  final favoritesAudit = Platform.environment['BOBTV_FAVORITES_AUDIT_COPY'];
  test(
    'installed favorite replay collapses First Theater category memberships',
    () async {
      final database = db.AppDatabase.forTesting(
        NativeDatabase(File(favoritesAudit!)),
      );
      addTearDown(database.close);
      final ids = await database.getAllFavoritedChannelIds();
      final rows = (await database.getChannelsByIds(
        ids,
      )).where((c) => c.name == '第一剧场').toList();
      expect(rows, isNotEmpty);
      final keys = await database.channelPresentationKeys(rows);
      final cards = ChannelPresentationIdentity.representatives(
        rows,
        idOf: (c) => c.id,
        keyOf: (c) => keys[c.id]!,
        scoreOf: (_) => 0,
      );
      // Counts only; no private stream addresses or device credentials.
      // ignore: avoid_print
      print(
        jsonEncode({
          'databaseCopyOnly': true,
          'sourceRows': rows.length,
          'favoriteCards': cards.length,
        }),
      );
      expect(cards.length, 1);
    },
    skip: favoritesAudit == null
        ? 'Set BOBTV_FAVORITES_AUDIT_COPY to a backup'
        : false,
  );

  final auditCopy = Platform.environment['BOBTV_CHANNEL_FIX_AUDIT_COPY'];
  test(
    'installed database copy groups Wind Theater without changing source rows',
    () async {
      final database = db.AppDatabase.forTesting(
        NativeDatabase(File(auditCopy!)),
      );
      addTearDown(database.close);
      final all = await database.getAllChannels();
      final selected = all.where((c) => c.name == '风云剧场').toList();
      expect(selected, isNotEmpty);
      final keys = await database.channelPresentationKeys(selected);
      final cards = ChannelPresentationIdentity.representatives(
        selected,
        idOf: (c) => c.id,
        keyOf: (c) => keys[c.id]!,
        scoreOf: (_) => 0,
      );
      expect(cards.length, 1);
      final choice = await database.channelMergeChoiceForChannel(cards.single);
      final members = await database.channelsForMergeChoice(choice);
      final before = all.length;
      expect(await database.getAllChannels(), hasLength(before));
      // Counts only; private route addresses never enter the test output.
      // ignore: avoid_print
      print(
        jsonEncode({
          'databaseCopyOnly': true,
          'channel': '风云剧场',
          'sourceRows': selected.length,
          'visibleCards': cards.length,
          'uniqueRoutes': choice.routeCount,
          'resolvedMemberRows': members.length,
          'databaseRowsPreserved': before,
        }),
      );
    },
    skip: auditCopy == null
        ? 'Set BOBTV_CHANNEL_FIX_AUDIT_COPY to a SQLite backup'
        : false,
  );

  testWidgets('same name and category does not disable another identity', (
    tester,
  ) async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await tester.runAsync(() => seed(database, group: international));
    final channel = await tester.runAsync(
      () async => (await database.getChannelsByIds({'one'})).single,
    );
    tester.view.physicalSize = const Size(1080, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    ChannelMergePlan? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              child: const Text('打开'),
              onPressed: () async {
                saved = await showDialog<ChannelMergePlan>(
                  context: context,
                  builder: (_) => ChannelMergeDialog(
                    database: database,
                    channel: channel!,
                    seedUrls: [channel.streamUrl],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    Future<void> ready() async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.tap(find.text('打开'));
    await ready();
    final tiles = tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .toList();
    expect(tiles, hasLength(3));
    expect(tiles.where((t) => t.onChanged == null), hasLength(1));
    final selectable = find.byWidgetPredicate(
      (w) => w is CheckboxListTile && w.onChanged != null && w.value == false,
    );
    // IDs are sorted: duplicate, one, two. Choose two for a distinct URL.
    await tester.tap(selectable.last);
    await tester.pump();
    await tester.tap(find.text('下一步'));
    await ready();
    expect(find.text('2 个频道 · 2 条去重线路'), findsOneWidget);
    await tester.tap(find.text('合并频道'));
    await ready();
    expect(saved?.urls.toSet(), {
      'https://media.example.org/a',
      'https://media.example.org/b',
    });
    expect(
      (await tester.runAsync(database.pendingSharedEvents))?.single['kind'],
      'merge',
    );
    expect(tester.takeException(), isNull);
  });
}
