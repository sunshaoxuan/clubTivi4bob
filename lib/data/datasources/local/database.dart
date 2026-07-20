import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../services/channel_category_classifier.dart';
import 'tables.dart';

part 'database.g.dart';

const _uuid = Uuid();

@DriftDatabase(
  tables: [
    Providers,
    Channels,
    StreamChecks,
    BlockedStreamRoutes,
    ProviderOrigins,
    GitHubCrawlRepositories,
    DiscoveredStreamSources,
    EpgSources,
    EpgChannels,
    EpgProgrammes,
    EpgMappings,
    ChannelGroups,
    FavoriteLists,
    FavoriteListChannels,
    EpgReminders,
    ScheduledRecordings,
    FailoverGroups,
    FailoverGroupChannels,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 8;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(favoriteLists);
        await m.createTable(favoriteListChannels);
      }
      if (from < 3) {
        await m.createTable(epgReminders);
        await m.createTable(scheduledRecordings);
      }
      if (from < 4) {
        await m.addColumn(epgProgrammes, epgProgrammes.subtitle);
        await m.addColumn(epgProgrammes, epgProgrammes.episodeNum);
      }
      if (from < 5) {
        await m.createTable(failoverGroups);
        await m.createTable(failoverGroupChannels);
      }
      if (from < 6) {
        await m.createTable(streamChecks);
        await m.createTable(providerOrigins);
      }
      if (from < 7) {
        await m.createTable(gitHubCrawlRepositories);
        await m.createTable(discoveredStreamSources);
      }
      if (from < 8) {
        await m.createTable(blockedStreamRoutes);
      }
    },
  );

  // --- Provider queries ---

  Future<List<Provider>> getAllProviders() => select(providers).get();

  Future<void> upsertProvider(ProvidersCompanion entry) =>
      into(providers).insertOnConflictUpdate(entry);

  Future<void> deleteProvider(String id) =>
      (delete(providers)..where((t) => t.id.equals(id))).go();

  Future<void> markProviderRefreshed(String id, DateTime refreshedAt) =>
      (update(providers)..where((t) => t.id.equals(id))).write(
        ProvidersCompanion(lastRefresh: Value(refreshedAt)),
      );

  Future<void> updateProviderUrl(String id, String url) => (update(
    providers,
  )..where((t) => t.id.equals(id))).write(ProvidersCompanion(url: Value(url)));

  // --- Channel queries ---

  Future<List<Channel>> getChannelsForProvider(String providerId) =>
      (select(channels)..where((t) => t.providerId.equals(providerId))).get();

  Future<List<Channel>> getChannelsByIds(Set<String> ids) =>
      (select(channels)..where((t) => t.id.isIn(ids))).get();

  /// Returns a small candidate set for one content category.
  ///
  /// Classification is finalized by [ChannelCategoryClassifier] in the UI.
  /// Keeping the broad text match in SQLite prevents tens of thousands of
  /// channel rows from being materialized on the Flutter isolate at startup.
  Future<List<Channel>> getChannelCategoryCandidates(String category) async {
    const termsByCategory = <String, List<String>>{
      '央视频道': ['cctv', '央视', '中央电视', 'cgtn'],
      '卫视频道': ['卫视', 'satellite'],
      '地方频道': [
        '地方',
        '本地',
        '省市',
        '省内',
        '北京',
        '天津',
        '上海',
        '重庆',
        '河北',
        '山西',
        '辽宁',
        '吉林',
        '黑龙江',
        '江苏',
        '浙江',
        '安徽',
        '福建',
        '江西',
        '山东',
        '河南',
        '湖北',
        '湖南',
        '广东',
        '海南',
        '四川',
        '贵州',
        '云南',
        '陕西',
        '甘肃',
        '青海',
        '内蒙古',
        '广西',
        '西藏',
        '宁夏',
        '新疆',
      ],
      '港澳台频道': [
        '港澳台',
        '香港',
        '澳门',
        '澳門',
        '台湾',
        '台灣',
        'tvb',
        '翡翠台',
        '明珠台',
        'viutv',
        'rthk',
      ],
      '国际频道': [
        '国际频道',
        'international',
        'general',
        'legislative',
        'religious',
        ' tv',
        'rai ',
        'rtl ',
        'fox ',
        'ion ',
      ],
      '体育频道': ['体育', '赛事', '足球', '篮球', '网球', '高尔夫', 'sports', 'sport'],
      '新闻频道': ['新闻', '资讯', 'news'],
      '电影剧集': ['电影', '影院', '影视', '剧场', '电视剧', 'movie', 'cinema'],
      '少儿频道': ['少儿', '卡通', '动漫', '动画', '儿童', 'kids', 'cartoon'],
      '纪录频道': ['纪录', '纪实', 'documentary', 'discovery'],
      '广播电台': ['广播', '电台', 'radio', 'fm ', 'am '],
      '网络直播': [
        '王者荣耀',
        '交友',
        '聊天电台',
        '英雄联盟',
        '星秀',
        '颜值',
        '派对',
        '一起看',
        '视频聊天',
        '和平精英',
        '聊天室',
        '虚拟singer',
        '虚拟日常',
        '弹幕互动',
        '社交互动游戏',
        '热门游戏',
        '原神',
        '崩坏',
        '穿越火线',
        '永劫无间',
        '怪物猎人',
        'qq飞车',
        'dota',
        'apex',
        '咪咕直播',
        '直播中国',
        '熊猫直播',
        '游戏风云',
        '电竞',
        '购物',
        '商城',
        'shop',
        'shopping',
      ],
    };

    final terms = termsByCategory[category];
    if (terms == null) {
      // "Other" is evaluated only when selected. SQL removes every row that
      // is an obvious member of another category before Dart sees the result.
      final allTerms = termsByCategory.values.expand((e) => e).toSet();
      final conditions = <String>[];
      final variables = <Variable<String>>[];
      for (final term in allTerms) {
        conditions.add(
          '(lower(name) LIKE ? OR lower(COALESCE(group_title, \'\')) LIKE ? '
          'OR lower(COALESCE(tvg_id, \'\')) LIKE ?)',
        );
        final pattern = '%${term.toLowerCase()}%';
        variables.addAll([
          Variable.withString(pattern),
          Variable.withString(pattern),
          Variable.withString(pattern),
        ]);
      }
      final rows = await customSelect(
        'SELECT * FROM channels WHERE NOT (${conditions.join(' OR ')})',
        variables: variables,
        readsFrom: {channels},
      ).get();
      return rows.map((row) => channels.map(row.data)).toList();
    }

    final conditions = <String>[];
    final variables = <Variable<String>>[];
    for (final term in terms) {
      conditions.add(
        '(lower(name) LIKE ? OR lower(COALESCE(group_title, \'\')) LIKE ? '
        'OR lower(COALESCE(tvg_id, \'\')) LIKE ?)',
      );
      final pattern = '%${term.toLowerCase()}%';
      variables.addAll([
        Variable.withString(pattern),
        Variable.withString(pattern),
        Variable.withString(pattern),
      ]);
    }
    if (category == '网络直播') {
      conditions.add(
        '(stream_url LIKE ? OR stream_url LIKE ? OR stream_url LIKE ? '
        'OR stream_url LIKE ? OR stream_url LIKE ? OR stream_url LIKE ?)',
      );
      variables.addAll([
        Variable.withString('%107.173.156.246%'),
        Variable.withString('%.huya.com%'),
        Variable.withString('%.douyu.com%'),
        Variable.withString('%.bilivideo.com%'),
        Variable.withString('%.kwimgs.com%'),
        Variable.withString('%#%'),
      ]);
    }
    final rows = await customSelect(
      'SELECT * FROM channels WHERE ${conditions.join(' OR ')}',
      variables: variables,
      readsFrom: {channels},
    ).get();
    return rows.map((row) => channels.map(row.data)).toList();
  }

  /// Get distinct group names per provider without loading channel objects.
  Future<Map<String, List<String>>> getProviderGroups() async {
    final rows = await customSelect(
      'SELECT DISTINCT provider_id, group_title FROM channels '
      'WHERE group_title IS NOT NULL AND group_title != \'\' '
      'ORDER BY provider_id, group_title',
    ).get();
    final result = <String, List<String>>{};
    for (final row in rows) {
      final pid = row.read<String>('provider_id');
      final g = row.read<String>('group_title');
      (result[pid] ??= []).add(g);
    }
    return result;
  }

  /// Get channels for a specific provider and group.
  Future<List<Channel>> getChannelsForProviderGroup(
    String providerId,
    String groupTitle,
  ) =>
      (select(channels)..where(
            (t) =>
                t.providerId.equals(providerId) &
                t.groupTitle.equals(groupTitle),
          ))
          .get();

  Future<List<Channel>> getFavoriteChannels() =>
      (select(channels)..where((t) => t.favorite.equals(true))).get();

  Future<void> upsertChannels(List<ChannelsCompanion> entries) async {
    final blockedUrls = {
      for (final route in await select(blockedStreamRoutes).get())
        route.streamUrl,
    };
    entries = entries.where((entry) {
      if (!entry.name.present || !entry.streamUrl.present) return true;
      if (blockedUrls.contains(entry.streamUrl.value)) return false;
      return !ChannelCategoryClassifier.isClearlyNonTelevisionRoute(
        name: entry.name.value,
        groupTitle: entry.groupTitle.present ? entry.groupTitle.value : null,
        streamUrl: entry.streamUrl.value,
      );
    }).toList();
    if (entries.isEmpty) return;
    await batch((b) {
      b.insertAllOnConflictUpdate(channels, entries);
    });
  }

  Future<int> purgeRejectedNonTelevisionChannels() async {
    final candidates = await getChannelCategoryCandidates('网络直播');
    final ids = candidates
        .where(
          (channel) => ChannelCategoryClassifier.isClearlyNonTelevisionRoute(
            name: channel.name,
            groupTitle: channel.groupTitle,
            streamUrl: channel.streamUrl,
          ),
        )
        .map((channel) => channel.id);
    return deleteChannelsByIds(ids);
  }

  Future<int> deleteChannelRoute(String channelId, String streamUrl) async {
    final selected = await (select(
      channels,
    )..where((table) => table.id.equals(channelId))).getSingleOrNull();
    if (selected == null) return 0;
    final matches =
        await (select(channels)..where(
              (table) =>
                  table.providerId.equals(selected.providerId) &
                  table.streamUrl.equals(streamUrl),
            ))
            .get();
    return deleteChannelsByIds(matches.map((channel) => channel.id));
  }

  Future<int> blockAndDeleteChannelRoute(
    String channelId,
    String streamUrl,
  ) async {
    await into(blockedStreamRoutes).insertOnConflictUpdate(
      BlockedStreamRoutesCompanion.insert(
        streamUrl: streamUrl,
        reason: 'static_advertising_frame',
      ),
    );
    return deleteChannelRoute(channelId, streamUrl);
  }

  Future<int> deleteChannelsByIds(Iterable<String> channelIds) async {
    final ids = channelIds.toSet().toList();
    if (ids.isEmpty) return 0;
    var deleted = 0;
    await transaction(() async {
      for (var offset = 0; offset < ids.length; offset += 400) {
        final end = (offset + 400).clamp(0, ids.length);
        final batchIds = ids.sublist(offset, end);
        await (delete(
          favoriteListChannels,
        )..where((t) => t.channelId.isIn(batchIds))).go();
        await (delete(
          failoverGroupChannels,
        )..where((t) => t.channelId.isIn(batchIds))).go();
        await (delete(
          epgMappings,
        )..where((t) => t.channelId.isIn(batchIds))).go();
        await (delete(
          discoveredStreamSources,
        )..where((t) => t.channelId.isIn(batchIds))).go();
        deleted += await (delete(
          channels,
        )..where((t) => t.id.isIn(batchIds))).go();
      }
    });
    return deleted;
  }

  Future<int> deleteChannelsMissingFromProvider(
    String providerId,
    Set<String> currentIds,
  ) async {
    final existing = await getChannelsForProvider(providerId);
    final staleIds = existing
        .where((channel) => !currentIds.contains(channel.id))
        .map((channel) => channel.id);
    return deleteChannelsByIds(staleIds);
  }

  Future<List<StreamCheck>> getAllStreamChecks() => select(streamChecks).get();

  Future<Set<String>> getRetiredChannelIds() async {
    final query = select(channels).join([
      innerJoin(
        streamChecks,
        streamChecks.providerId.equalsExp(channels.providerId) &
            streamChecks.streamUrl.equalsExp(channels.streamUrl),
      ),
    ])..where(streamChecks.retired.equals(true));
    final rows = await query.get();
    return rows.map((row) => row.readTable(channels).id).toSet();
  }

  Future<List<({Channel channel, StreamCheck? check})>>
  getMaintenanceCandidates({
    required DateTime checkBefore,
    required int limit,
  }) async {
    final query = select(channels).join([
      leftOuterJoin(
        streamChecks,
        streamChecks.providerId.equalsExp(channels.providerId) &
            streamChecks.streamUrl.equalsExp(channels.streamUrl),
      ),
    ]);
    query
      ..where(
        (channels.streamUrl.like('http://%') |
                channels.streamUrl.like('https://%')) &
            (streamChecks.retired.isNull() |
                streamChecks.retired.equals(false)) &
            (streamChecks.lastCheckedAt.isNull() |
                streamChecks.lastCheckedAt.isSmallerThanValue(checkBefore)),
      )
      ..orderBy([
        OrderingTerm.desc(streamChecks.consecutiveFailures),
        OrderingTerm.asc(streamChecks.lastCheckedAt),
      ])
      ..limit(limit * 2);
    final rows = await query.get();
    return rows
        .map(
          (row) => (
            channel: row.readTable(channels),
            check: row.readTableOrNull(streamChecks),
          ),
        )
        .toList();
  }

  Future<void> upsertStreamChecks(List<StreamChecksCompanion> entries) async {
    if (entries.isEmpty) return;
    await batch((batch) {
      batch.insertAllOnConflictUpdate(streamChecks, entries);
    });
  }

  Future<Set<String>> getRetiredStreamUrls(String providerId) async {
    final rows =
        await (select(streamChecks)..where(
              (table) =>
                  table.providerId.equals(providerId) &
                  table.retired.equals(true),
            ))
            .get();
    return rows.map((row) => row.streamUrl).toSet();
  }

  Future<void> resetRetiredStreamChecks(String providerId) =>
      (update(
        streamChecks,
      )..where((t) => t.providerId.equals(providerId))).write(
        const StreamChecksCompanion(
          consecutiveFailures: Value(0),
          firstFailureAt: Value(null),
          lastCheckedAt: Value(null),
          retired: Value(false),
        ),
      );

  Future<List<ProviderOrigin>> getAllProviderOrigins() =>
      select(providerOrigins).get();

  Future<void> upsertProviderOrigin(ProviderOriginsCompanion entry) =>
      into(providerOrigins).insertOnConflictUpdate(entry);

  Future<List<GitHubCrawlRepository>> getGitHubCrawlRepositories() =>
      select(gitHubCrawlRepositories).get();

  Future<void> upsertGitHubCrawlRepository(
    GitHubCrawlRepositoriesCompanion entry,
  ) => into(gitHubCrawlRepositories).insertOnConflictUpdate(entry);

  Future<List<DiscoveredStreamSource>> getDiscoveredStreamSources() =>
      select(discoveredStreamSources).get();

  Future<void> upsertDiscoveredStreamSources(
    List<DiscoveredStreamSourcesCompanion> entries,
  ) async {
    if (entries.isEmpty) return;
    await batch((batch) {
      batch.insertAllOnConflictUpdate(discoveredStreamSources, entries);
    });
  }

  Future<int> deleteDiscoveredMissingFromDocument({
    required String owner,
    required String repo,
    required String path,
    required Set<String> currentChannelIds,
  }) async {
    final existing =
        await (select(discoveredStreamSources)..where(
              (table) =>
                  table.githubOwner.equals(owner) &
                  table.githubRepo.equals(repo) &
                  table.githubPath.equals(path),
            ))
            .get();
    final staleIds = existing
        .where((item) => !currentChannelIds.contains(item.channelId))
        .map((item) => item.channelId)
        .toSet();
    if (staleIds.isEmpty) return 0;
    await (delete(
      discoveredStreamSources,
    )..where((table) => table.channelId.isIn(staleIds))).go();
    return deleteChannelsByIds(staleIds);
  }

  Future<void> resetRetiredStreamUrls(
    String providerId,
    Set<String> urls,
  ) async {
    if (urls.isEmpty) return;
    for (var offset = 0; offset < urls.length; offset += 400) {
      final values = urls.skip(offset).take(400).toList();
      await (update(streamChecks)..where(
            (table) =>
                table.providerId.equals(providerId) &
                table.streamUrl.isIn(values),
          ))
          .write(
            const StreamChecksCompanion(
              consecutiveFailures: Value(0),
              firstFailureAt: Value(null),
              lastCheckedAt: Value(null),
              retired: Value(false),
            ),
          );
    }
  }

  Future<void> updateChannelLogo(String channelId, String logoUrl) =>
      (update(channels)..where((t) => t.id.equals(channelId))).write(
        ChannelsCompanion(tvgLogo: Value(logoUrl)),
      );

  /// Batch-update logos for multiple channels in a single transaction.
  Future<void> updateChannelLogos(Map<String, String> idToLogoUrl) async {
    await batch((b) {
      for (final entry in idToLogoUrl.entries) {
        b.update(
          channels,
          ChannelsCompanion(tvgLogo: Value(entry.value)),
          where: (t) => t.id.equals(entry.key),
        );
      }
    });
  }

  Future<void> renameChannel(
    String channelId,
    String providerId,
    String newName,
  ) => (update(channels)..where((t) => t.id.equals(channelId))).write(
    ChannelsCompanion(name: Value(newName)),
  );

  Future<void> toggleFavorite(String channelId) async {
    final channel = await (select(
      channels,
    )..where((t) => t.id.equals(channelId))).getSingle();
    await (update(channels)..where((t) => t.id.equals(channelId))).write(
      ChannelsCompanion(favorite: Value(!channel.favorite)),
    );
  }

  // --- EPG Source queries ---

  Future<List<EpgSource>> getAllEpgSources() => select(epgSources).get();

  Future<void> upsertEpgSource(EpgSourcesCompanion entry) =>
      into(epgSources).insertOnConflictUpdate(entry);

  // --- EPG Channel queries ---

  Future<List<EpgChannel>> getEpgChannelsForSource(String sourceId) =>
      (select(epgChannels)..where((t) => t.sourceId.equals(sourceId))).get();

  Future<void> upsertEpgChannels(List<EpgChannelsCompanion> entries) async {
    await batch((b) {
      b.insertAllOnConflictUpdate(epgChannels, entries);
    });
  }

  // --- EPG Programme queries ---

  Future<List<EpgProgramme>> getProgrammes({
    required String epgChannelId,
    required DateTime start,
    required DateTime end,
  }) =>
      (select(epgProgrammes)
            ..where(
              (t) =>
                  t.epgChannelId.equals(epgChannelId) &
                  t.start.isBiggerOrEqualValue(start) &
                  t.stop.isSmallerOrEqualValue(end),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.start)]))
          .get();

  /// Get what's on now for a list of EPG channel IDs.
  Future<List<EpgProgramme>> getNowPlaying(List<String> epgChannelIds) {
    final now = DateTime.now();
    return (select(epgProgrammes)..where(
          (t) =>
              t.epgChannelId.isIn(epgChannelIds) &
              t.start.isSmallerOrEqualValue(now) &
              t.stop.isBiggerOrEqualValue(now),
        ))
        .get();
  }

  Future<List<EpgProgramme>> getNowPlayingWindow(
    List<String> epgChannelIds,
    DateTime from,
    DateTime to,
  ) {
    return (select(epgProgrammes)..where(
          (t) =>
              t.epgChannelId.isIn(epgChannelIds) &
              t.start.isSmallerOrEqualValue(to) &
              t.stop.isBiggerOrEqualValue(from),
        ))
        .get();
  }

  Future<void> insertProgrammes(List<EpgProgrammesCompanion> entries) async {
    await batch((b) {
      b.insertAll(epgProgrammes, entries, mode: InsertMode.insertOrReplace);
    });
  }

  Future<void> deleteEpgProgrammesForSource(String sourceId) =>
      (delete(epgProgrammes)..where((t) => t.sourceId.equals(sourceId))).go();

  Future<void> insertEpgProgrammes(List<EpgProgrammesCompanion> entries) async {
    await batch((b) {
      b.insertAll(epgProgrammes, entries);
    });
  }

  Future<void> updateEpgSourceRefreshTime(String id) =>
      (update(epgSources)..where((t) => t.id.equals(id))).write(
        EpgSourcesCompanion(lastRefresh: Value(DateTime.now())),
      );

  Future<void> deleteEpgSource(String id) async {
    await deleteEpgProgrammesForSource(id);
    await (delete(epgChannels)..where((t) => t.sourceId.equals(id))).go();
    await (delete(epgSources)..where((t) => t.id.equals(id))).go();
  }

  Future<List<Channel>> getAllChannels() => select(channels).get();

  Future<List<String>> getChannelNameSample({int limit = 80}) async {
    final query = selectOnly(channels, distinct: true)
      ..addColumns([channels.name])
      ..limit(limit);
    final rows = await query.get();
    return rows.map((row) => row.read(channels.name)!).toList();
  }

  /// Delete old programmes to keep DB size manageable.
  Future<void> pruneOldProgrammes({Duration maxAge = const Duration(days: 7)}) {
    final cutoff = DateTime.now().subtract(maxAge);
    return (delete(
      epgProgrammes,
    )..where((t) => t.stop.isSmallerThanValue(cutoff))).go();
  }

  // --- EPG Mapping queries ---

  Future<List<EpgMapping>> getAllMappings() => select(epgMappings).get();

  Future<List<EpgMapping>> getMappingsForChannelIds(Set<String> ids) async {
    if (ids.isEmpty) return const [];
    final result = <EpgMapping>[];
    final values = ids.toList(growable: false);
    // Stay below SQLite's parameter limit on every supported platform.
    for (var start = 0; start < values.length; start += 800) {
      final end = (start + 800).clamp(0, values.length);
      final chunk = values.sublist(start, end);
      result.addAll(
        await (select(
          epgMappings,
        )..where((t) => t.channelId.isIn(chunk))).get(),
      );
    }
    return result;
  }

  Future<void> upsertMapping(EpgMappingsCompanion entry) =>
      into(epgMappings).insertOnConflictUpdate(entry);

  Future<void> upsertMappings(List<EpgMappingsCompanion> entries) async {
    await batch((b) {
      b.insertAllOnConflictUpdate(epgMappings, entries);
    });
  }

  Future<void> deleteMapping(String channelId, String providerId) =>
      (delete(epgMappings)..where(
            (t) =>
                t.channelId.equals(channelId) & t.providerId.equals(providerId),
          ))
          .go();

  Future<void> deleteAllMappings() => delete(epgMappings).go();

  /// Get mapping stats.
  Future<Map<String, int>> getMappingStats() async {
    final all = await select(epgMappings).get();
    int mapped = 0, suggested = 0;
    for (final m in all) {
      if (m.source == 'auto' || m.source == 'manual') {
        mapped++;
      } else {
        suggested++;
      }
    }
    return {'mapped': mapped, 'suggested': suggested};
  }

  // --- Favorite List queries ---

  Future<List<FavoriteList>> getAllFavoriteLists() => (select(
    favoriteLists,
  )..orderBy([(t) => OrderingTerm.asc(t.sortOrder)])).get();

  Future<List<Channel>> getChannelsInList(String listId) async {
    final query =
        select(channels).join([
            innerJoin(
              favoriteListChannels,
              favoriteListChannels.channelId.equalsExp(channels.id),
            ),
          ])
          ..where(favoriteListChannels.listId.equals(listId))
          ..orderBy([OrderingTerm.asc(favoriteListChannels.sortOrder)]);
    final rows = await query.get();
    return rows.map((row) => row.readTable(channels)).toList();
  }

  Future<void> addChannelToList(String listId, String channelId) =>
      into(favoriteListChannels).insertOnConflictUpdate(
        FavoriteListChannelsCompanion.insert(
          listId: listId,
          channelId: channelId,
        ),
      );

  Future<void> removeChannelFromList(String listId, String channelId) =>
      (delete(favoriteListChannels)..where(
            (t) => t.listId.equals(listId) & t.channelId.equals(channelId),
          ))
          .go();

  Future<FavoriteList> createFavoriteList(String name) async {
    final id = _uuid.v4();
    final count = await (select(favoriteLists)..limit(1000)).get();
    final entry = FavoriteListsCompanion.insert(
      id: id,
      name: name,
      sortOrder: Value(count.length),
    );
    await into(favoriteLists).insert(entry);
    return (select(favoriteLists)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> renameFavoriteList(String id, String name) =>
      (update(favoriteLists)..where((t) => t.id.equals(id))).write(
        FavoriteListsCompanion(name: Value(name)),
      );

  Future<void> deleteFavoriteList(String id) async {
    await (delete(
      favoriteListChannels,
    )..where((t) => t.listId.equals(id))).go();
    await (delete(favoriteLists)..where((t) => t.id.equals(id))).go();
  }

  Future<bool> isChannelInList(String listId, String channelId) async {
    final row =
        await (select(favoriteListChannels)..where(
              (t) => t.listId.equals(listId) & t.channelId.equals(channelId),
            ))
            .getSingleOrNull();
    return row != null;
  }

  Future<List<FavoriteList>> getListsForChannel(String channelId) async {
    final query = select(favoriteLists).join([
      innerJoin(
        favoriteListChannels,
        favoriteListChannels.listId.equalsExp(favoriteLists.id),
      ),
    ])..where(favoriteListChannels.channelId.equals(channelId));
    final rows = await query.get();
    return rows.map((row) => row.readTable(favoriteLists)).toList();
  }

  /// Get all channel IDs that belong to any favorite list.
  Future<Set<String>> getAllFavoritedChannelIds() async {
    final rows = await select(favoriteListChannels).get();
    return rows.map((r) => r.channelId).toSet();
  }

  // --- Reminder queries ---

  Future<void> addReminder(EpgRemindersCompanion entry) =>
      into(epgReminders).insertOnConflictUpdate(entry);

  Future<void> deleteReminder(String id) =>
      (delete(epgReminders)..where((t) => t.id.equals(id))).go();

  Future<List<EpgReminder>> getActiveReminders() =>
      (select(epgReminders)..where((t) => t.fired.equals(false))).get();

  Future<List<EpgReminder>> getRemindersForTimeRange(
    DateTime start,
    DateTime end,
  ) =>
      (select(epgReminders)..where(
            (t) =>
                t.programmeStart.isBiggerOrEqualValue(start) &
                t.programmeStart.isSmallerOrEqualValue(end),
          ))
          .get();

  Future<void> markReminderFired(String id) =>
      (update(epgReminders)..where((t) => t.id.equals(id))).write(
        const EpgRemindersCompanion(fired: Value(true)),
      );

  // --- Scheduled Recording queries ---

  Future<void> addScheduledRecording(ScheduledRecordingsCompanion entry) =>
      into(scheduledRecordings).insertOnConflictUpdate(entry);

  Future<void> deleteScheduledRecording(String id) =>
      (delete(scheduledRecordings)..where((t) => t.id.equals(id))).go();

  Future<List<ScheduledRecording>> getAllScheduledRecordings() =>
      select(scheduledRecordings).get();

  Future<List<ScheduledRecording>> getScheduledRecordingsForTimeRange(
    DateTime start,
    DateTime end,
  ) =>
      (select(scheduledRecordings)..where(
            (t) =>
                t.programmeStart.isBiggerOrEqualValue(start) &
                t.programmeStart.isSmallerOrEqualValue(end),
          ))
          .get();

  Future<void> updateRecordingStatus(String id, String status) =>
      (update(scheduledRecordings)..where((t) => t.id.equals(id))).write(
        ScheduledRecordingsCompanion(status: Value(status)),
      );

  // --- Failover Group queries ---

  Future<List<FailoverGroup>> getAllFailoverGroups() => (select(
    failoverGroups,
  )..orderBy([(t) => OrderingTerm.asc(t.name)])).get();

  Future<FailoverGroup> createFailoverGroup(String name) async {
    final id = await into(
      failoverGroups,
    ).insert(FailoverGroupsCompanion.insert(name: name));
    return (select(failoverGroups)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> addChannelsToFailoverGroup(
    int groupId,
    List<String> channelIds,
  ) async {
    await batch((b) {
      for (var i = 0; i < channelIds.length; i++) {
        b.insert(
          failoverGroupChannels,
          FailoverGroupChannelsCompanion.insert(
            groupId: groupId,
            channelId: channelIds[i],
            priority: Value(i),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Future<List<FailoverGroupChannel>> getFailoverGroupMembers(int groupId) =>
      (select(failoverGroupChannels)
            ..where((t) => t.groupId.equals(groupId))
            ..orderBy([(t) => OrderingTerm.asc(t.priority)]))
          .get();

  /// Get all failover group memberships keyed by channel ID for fast lookup.
  Future<Map<String, List<FailoverGroupMembership>>>
  getFailoverGroupIndex() async {
    final groups = await getAllFailoverGroups();
    final members = await select(failoverGroupChannels).get();
    final groupMap = {for (final g in groups) g.id: g};
    final index = <String, List<FailoverGroupMembership>>{};
    for (final m in members) {
      final group = groupMap[m.groupId];
      if (group == null) continue;
      index
          .putIfAbsent(m.channelId, () => [])
          .add(FailoverGroupMembership(group: group, priority: m.priority));
    }
    return index;
  }

  Future<void> deleteFailoverGroup(int groupId) async {
    await (delete(
      failoverGroupChannels,
    )..where((t) => t.groupId.equals(groupId))).go();
    await (delete(failoverGroups)..where((t) => t.id.equals(groupId))).go();
  }

  Future<void> renameFailoverGroup(int groupId, String name) =>
      (update(failoverGroups)..where((t) => t.id.equals(groupId))).write(
        FailoverGroupsCompanion(name: Value(name)),
      );

  Future<void> removeChannelFromFailoverGroup(int groupId, String channelId) =>
      (delete(failoverGroupChannels)..where(
            (t) => t.groupId.equals(groupId) & t.channelId.equals(channelId),
          ))
          .go();
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'clubtivi', 'clubtivi.db'));
    await file.parent.create(recursive: true);

    // Migrate from old ~/Documents location if the new DB doesn't exist yet.
    if (!await file.exists()) {
      final oldDir = await getApplicationDocumentsDirectory();
      final oldFile = File(p.join(oldDir.path, 'clubtivi', 'clubtivi.db'));
      if (await oldFile.exists()) {
        await oldFile.copy(file.path);
      }
    }

    return NativeDatabase.createInBackground(file);
  });
}

/// Lightweight struct for failover group membership lookups.
class FailoverGroupMembership {
  final FailoverGroup group;
  final int priority;
  const FailoverGroupMembership({required this.group, required this.priority});
}
