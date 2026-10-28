import 'dart:io';
import 'dart:isolate';
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/channel_category_classifier.dart';
import '../../services/public_inventory_policy.dart';
import '../../services/route_identity.dart';
import '../../services/manual_channel_category.dart';
import '../../services/channel_merge.dart';
import '../../services/channel_route_transfer.dart';
import '../../services/bobtv_api_client.dart';
import '../../services/channel_presentation_identity.dart';
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
  Future<void>? _favoriteExpansion;
  bool _favoriteExpansionDone = false;
  factory AppDatabase() => AppDatabase._(_DatabaseWorker());

  AppDatabase._(_DatabaseWorker worker)
      : _worker = worker,
        super(_openConnection(worker));

  AppDatabase.forTesting(super.e) : _worker = null;

  final _DatabaseWorker? _worker;

  Future<void>? _closing;

  // Provider disposal and explicit exit share the native close acknowledgement.
  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    await super.close();
    // Drift's terminate request can reply before SQLite function destructors
    // finish. Keep the Flutter VM alive until the owning isolate has exited.
    await _worker?.waitForExit();
  }

  @override
  int get schemaVersion => 8;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    beforeOpen: (_) => _initializeSharedSync(),
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

  Future<void> _initializeSharedSync() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS catalog_epg_routes '
      '(local_channel_id TEXT PRIMARY KEY, catalog_channel_id TEXT NOT NULL, '
      'identity_hash TEXT NOT NULL, name TEXT NOT NULL, epg_id TEXT, group_name TEXT)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS catalog_presentation_context '
      '(local_channel_id TEXT PRIMARY KEY, country_code TEXT, region_code TEXT)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS catalog_epg_identity_version '
      '(id INTEGER PRIMARY KEY CHECK(id=1), version TEXT NOT NULL)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS catalog_route_categories '
      '(local_channel_id TEXT PRIMARY KEY, groups_json TEXT NOT NULL)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS server_epg_receipt '
      '(id INTEGER PRIMARY KEY CHECK(id=1), manifest TEXT NOT NULL)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS server_epg_identities '
      '(channel_id TEXT PRIMARY KEY, metadata TEXT NOT NULL)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS server_epg_attributions '
      '(source_id TEXT PRIMARY KEY, metadata TEXT NOT NULL)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS catalog_sync_manifest '
      '(id INTEGER PRIMARY KEY CHECK(id=1), version TEXT NOT NULL)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS channel_merge_overrides '
      '(url TEXT PRIMARY KEY, merge_id TEXT NOT NULL, name TEXT NOT NULL, '
      'group_name TEXT NOT NULL, epg_id TEXT, logo_url TEXT)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS channel_route_transfers '
      '(url TEXT PRIMARY KEY, name TEXT NOT NULL, group_name TEXT NOT NULL, '
      'epg_id TEXT, logo_url TEXT)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS shared_sync_control (id INTEGER PRIMARY KEY, suppressed INTEGER NOT NULL)',
    );
    await customStatement(
      'INSERT OR IGNORE INTO shared_sync_control VALUES(1,0)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS shared_sync_state (url TEXT PRIMARY KEY, revision INTEGER NOT NULL DEFAULT 0, score REAL)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS shared_sync_outbox (id TEXT PRIMARY KEY, coalesce_key TEXT UNIQUE, url TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL)',
    );
    // SQL triggers capture every import/edit/delete atomically with the data.
    // Personal/account-bearing providers never enter the public queue.
    final ids = sharedInventoryProviderIds.map((id) => "'$id'").join(',');
    final eligible =
        "EXISTS(SELECT 1 FROM providers p WHERE p.id=NEW.provider_id AND p.type!='xtream' AND COALESCE(p.username,'')='' AND COALESCE(p.password,'')='' AND (p.id IN ($ids) OR ((p.url LIKE 'https://raw.githubusercontent.com/%' OR p.url LIKE 'https://github.com/%' OR p.url LIKE 'https://%.github.io/%') AND p.url NOT LIKE '%?%' AND p.url NOT LIKE '%#%' AND p.url NOT LIKE '%@%')))";
    for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
      final owner = operation == 'DELETE' ? 'OLD' : 'NEW';
      final kind = operation == 'DELETE' ? 'delete' : 'upsert';
      final changed = operation == 'UPDATE'
          ? 'AND (OLD.name IS NOT NEW.name OR OLD.stream_url IS NOT NEW.stream_url OR OLD.group_title IS NOT NEW.group_title OR OLD.tvg_id IS NOT NEW.tvg_id OR OLD.tvg_logo IS NOT NEW.tvg_logo)'
          : operation == 'DELETE'
          ? 'AND NOT EXISTS(SELECT 1 FROM channels WHERE stream_url=OLD.stream_url)'
          : '';
      await customStatement(
        '''CREATE TRIGGER IF NOT EXISTS shared_sync_${operation.toLowerCase()}
        AFTER $operation ON channels WHEN (SELECT suppressed FROM shared_sync_control WHERE id=1)=0
        AND ${eligible.replaceAll('NEW.', '$owner.')} $changed BEGIN
        INSERT INTO shared_sync_outbox(id,coalesce_key,url,kind,payload)
        VALUES(lower(hex(randomblob(16))), '$kind:'||$owner.stream_url, $owner.stream_url,'$kind',
        json_object('name',$owner.name,'group',COALESCE($owner.group_title,'其他'),'source',$owner.provider_id,'epgId',$owner.tvg_id,'logoUrl',$owner.tvg_logo))
        ON CONFLICT(coalesce_key) DO UPDATE SET id=excluded.id,payload=excluded.payload;
        END''',
      );
    }
    for (final operation in ['INSERT', 'UPDATE']) {
      await customStatement(
        '''CREATE TRIGGER IF NOT EXISTS shared_sync_retire_${operation.toLowerCase()}
      AFTER $operation ON blocked_stream_routes WHEN NEW.reason NOT LIKE 'private:%' AND NEW.reason!='shared_catalog_retired'
      AND (SELECT suppressed FROM shared_sync_control WHERE id=1)=0 BEGIN
      INSERT INTO shared_sync_outbox(id,coalesce_key,url,kind,payload) VALUES(lower(hex(randomblob(16))), 'retire:'||NEW.stream_url,NEW.stream_url,'retire','{}')
      ON CONFLICT(coalesce_key) DO UPDATE SET id=excluded.id; END''',
      );
    }
    await customStatement(
      'CREATE TABLE IF NOT EXISTS shared_sync_migrations (name TEXT PRIMARY KEY)',
    );
  }

  /// Preference plugins belong to the application lifecycle, not database open.
  /// A failed preference read leaves migration pending for the next sync attempt.
  Future<void> migrateLegacySharedEdits() async {
    if ((await customSelect(
      "SELECT name FROM shared_sync_migrations WHERE name='legacy-v1'",
    ).get()).isEmpty) {
      await transaction(() async {
        final prefs = await SharedPreferences.getInstance();
        for (final entry in (await ManualChannelCategory.load()).entries) {
          await queueSharedEvent(entry.key, 'classify', {
            'group': entry.value.group,
            'baseRevision': await sharedRouteRevision(entry.key),
          });
        }
        Object? old;
        try {
          old = jsonDecode(prefs.getString('stream_health_scores') ?? '{}');
        } catch (_) {
          old = {};
        }
        if (old is Map) {
          for (final value in old.values) {
            if (value is! Map || value['url'] is! String) continue;
            final success = value['ok'] is int
                ? (value['ok'] as int).clamp(0, 10)
                : 0;
            final failure = value['fail'] is int
                ? (value['fail'] as int).clamp(0, 10)
                : 0;
            if (success + failure > 0)
              await queueSharedEvent(value['url'] as String, 'health', {
                'success': success,
                'failure': failure,
              });
          }
        }
        await customStatement(
          "INSERT OR IGNORE INTO shared_sync_migrations VALUES('legacy-v1')",
        );
      });
    }
  }

  Future<T> withoutSharedReporting<T>(Future<T> Function() action) =>
      transaction(() async {
        final original = (await customSelect(
          'SELECT suppressed FROM shared_sync_control WHERE id=1',
        ).getSingle()).read<int>('suppressed');
        await customStatement(
          'UPDATE shared_sync_control SET suppressed=1 WHERE id=1',
        );
        try {
          return await action();
        } finally {
          await customStatement(
            'UPDATE shared_sync_control SET suppressed=? WHERE id=1',
            [original],
          );
        }
      });

  Future<String?> sharedCatalogVersion() async {
    final rows = await customSelect(
      'SELECT version FROM catalog_sync_manifest WHERE id=1',
    ).get();
    return rows.firstOrNull?.read<String>('version');
  }

  /// Server-owned identity only. Excludes retired and manually blocked routes.
  Future<List<Channel>> publicRoutesForCatalogChannel(String catalogId) async {
    final rows = await customSelect(
      'SELECT c.* FROM channels c JOIN catalog_epg_routes r '
      'ON r.local_channel_id=c.id WHERE r.catalog_channel_id=? '
      'AND c.provider_id=?',
      variables: [Variable.withString(catalogId),
        Variable.withString('bobtv-channel-catalog')],
      readsFrom: {channels},
    ).get();
    final blocked = await getBlockedStreamUrls();
    final retired = await getRetiredChannelIds();
    return rows.map((row) => channels.map(row.data)).where((channel) =>
      !retired.contains(channel.id) &&
      !blocked.contains(canonicalRouteUrl(channel.streamUrl))).toList();
  }

  /// Exact server-owned channel identity for the selected local route rows.
  /// No name matching, classification or new persistent cache is involved.
  Future<Map<String, String>> publicCatalogChannelIds(Iterable<String> localIds) async {
    final ids = localIds.toSet().toList();
    final result = <String, String>{};
    for (var offset = 0; offset < ids.length; offset += 400) {
      final page = ids.skip(offset).take(400).toList();
      final rows = await customSelect(
        'SELECT local_channel_id,catalog_channel_id FROM catalog_epg_routes '
        'WHERE local_channel_id IN (${List.filled(page.length, '?').join(',')})',
        variables: page.map(Variable.withString).toList(),
      ).get();
      for (final row in rows) {
        result[row.read<String>('local_channel_id')] = row.read<String>('catalog_channel_id');
      }
      // A queued manual transfer is an explicit route-to-route choice. Reflect
      // it until the server receipt arrives, without inferring any name match.
      final transfers = await customSelect('''
        SELECT c.id AS source_id,t.id AS target_id,
          coalesce(r.catalog_channel_id,'manual-transfer:' || t.stream_url) AS identity
        FROM shared_sync_outbox o
        JOIN channels c ON c.stream_url=o.url
        JOIN channels t ON t.stream_url=json_extract(o.payload,'\$.targetUrl')
        LEFT JOIN catalog_epg_routes r ON r.local_channel_id=t.id
        WHERE o.kind='transfer' AND c.provider_id='bobtv-channel-catalog'
          AND t.provider_id='bobtv-channel-catalog'
          AND (c.id IN (${List.filled(page.length, '?').join(',')})
            OR t.id IN (${List.filled(page.length, '?').join(',')}))
      ''', variables: [...page, ...page].map(Variable.withString).toList()).get();
      final requested = page.toSet();
      for (final transfer in transfers) {
        for (final key in ['source_id', 'target_id']) {
          final id = transfer.read<String>(key);
          if (requested.contains(id)) result[id] = transfer.read<String>('identity');
        }
      }
    }
    return result;
  }

  Future<void> setSharedCatalogVersion(String? version) async {
    if (version == null) {
      await customStatement('DELETE FROM catalog_sync_manifest WHERE id=1');
    } else {
      await customStatement(
        'INSERT INTO catalog_sync_manifest(id,version) VALUES(1,?) '
        'ON CONFLICT(id) DO UPDATE SET version=excluded.version',
        [version],
      );
    }
  }

  Future<Map<String, List<String>>> publicCatalogCategoryGroups(
    Iterable<String> ids,
  ) async {
    final result = <String, List<String>>{};
    final unique = ids.toSet().toList();
    for (var offset = 0; offset < unique.length; offset += 300) {
      final rows = await customSelect('''
        SELECT a.local_channel_id,a.groups_json FROM catalog_route_categories a
        JOIN catalog_epg_routes r ON r.local_channel_id=a.local_channel_id
        JOIN channels c ON c.id=a.local_channel_id
        WHERE c.group_title=r.group_name AND a.local_channel_id IN
          (SELECT value FROM json_each(?))
      ''', variables: [Variable(jsonEncode(unique.skip(offset).take(300).toList()))]).get();
      for (final row in rows) {
        result[row.read<String>('local_channel_id')] =
            (jsonDecode(row.read<String>('groups_json')) as List).cast<String>();
      }
    }
    return result;
  }

  Future<int> sharedRouteRevision(String url) async {
    final rows = await customSelect(
      'SELECT revision FROM shared_sync_state WHERE url=?',
      variables: [Variable(url)],
    ).get();
    return rows.isEmpty ? 0 : rows.single.read<int>('revision');
  }

  Future<void> setSharedRouteState(
    String url,
    int revision, {
    double? score,
  }) => customStatement(
    'INSERT INTO shared_sync_state(url,revision,score) VALUES(?,?,?) ON CONFLICT(url) DO UPDATE SET revision=MAX(excluded.revision,shared_sync_state.revision),score=COALESCE(excluded.score,shared_sync_state.score)',
    [url, revision, score],
  );

  Future<Map<String, int>> sharedRouteRevisions() async => {
    for (final row in await customSelect(
      'SELECT url,revision FROM shared_sync_state',
    ).get())
      row.read<String>('url'): row.read<int>('revision'),
  };

  Future<void> setSharedRouteStates(
    Iterable<Map<String, Object?>> records,
  ) => batch((b) {
    for (final record in records)
      b.customStatement(
        'INSERT INTO shared_sync_state(url,revision,score) VALUES(?,?,?) ON CONFLICT(url) DO UPDATE SET revision=MAX(excluded.revision,shared_sync_state.revision),score=COALESCE(excluded.score,shared_sync_state.score)',
        [record['url'], record['revision'], record['healthScore']],
      );
  });

  Future<Set<String>> pendingSharedRemovedUrls() async => {
    for (final row in await customSelect(
      "SELECT DISTINCT url FROM shared_sync_outbox WHERE kind IN ('delete','retire')",
    ).get())
      row.read<String>('url'),
  };

  Future<void> queueSharedEvent(
    String url,
    String kind,
    Map<String, Object?> payload,
  ) async {
    final owners = await getChannelsByStreamUrls([url]);
    final eligible = {
      for (final p in await getAllProviders())
        if (isSharedInventoryProvider(
          id: p.id,
          type: p.type,
          url: p.url,
          username: p.username,
          password: p.password,
        ))
          p.id,
    };
    if (!owners.any((c) => eligible.contains(c.providerId))) return;
    if (kind == 'classify')
      await customStatement(
        "DELETE FROM shared_sync_outbox WHERE url=? AND kind='classify'",
        [url],
      );
    await customStatement(
      'INSERT INTO shared_sync_outbox(id,url,kind,payload) VALUES(?,?,?,?)',
      [_uuid.v4(), url, kind, jsonEncode(payload)],
    );
  }

  Future<List<Map<String, Object?>>> pendingSharedEvents({
    int limit = 100,
    Set<String> excludedIds = const {},
  }) async {
    final rows = await customSelect(
      "SELECT id,url,kind,payload FROM shared_sync_outbox WHERE id NOT IN (SELECT value FROM json_each(?)) ORDER BY CASE kind WHEN 'retire' THEN 0 WHEN 'delete' THEN 1 WHEN 'upsert' THEN 2 WHEN 'classify' THEN 3 WHEN 'merge' THEN 3 WHEN 'transfer' THEN 3 ELSE 4 END,rowid LIMIT ?",
      variables: [Variable(jsonEncode(excludedIds.toList())), Variable(limit)],
    ).get();
    return [
      for (final row in rows)
        {
          'id': row.read<String>('id'),
          'url': row.read<String>('url'),
          'kind': row.read<String>('kind'),
          'payload': jsonDecode(row.read<String>('payload')),
        },
    ];
  }

  Future<void> acknowledgeSharedEvent(String id) =>
      customStatement('DELETE FROM shared_sync_outbox WHERE id=?', [id]);

  Future<void> advanceQueuedCategoryRevision(
    String url,
    int oldRevision,
    int revision,
  ) => customStatement(
    "UPDATE shared_sync_outbox SET payload=json_set(payload,'\$.baseRevision',?) WHERE url=? AND kind='classify' AND json_extract(payload,'\$.baseRevision')=?",
    [revision, url, oldRevision],
  );

  Future<void> advanceQueuedTransferRevision(
    String url,
    int oldRevision,
    int revision,
  ) async {
    for (final field in ['baseRevision', 'targetRevision']) {
      final owner = field == 'baseRevision' ? 'url' : 'targetUrl';
      await customStatement(
        "UPDATE shared_sync_outbox SET payload=json_set(payload,'\$.$field',?) "
        "WHERE kind='transfer' AND json_extract(payload,'\$.$owner')=? "
        "AND json_extract(payload,'\$.$field')=?",
        [revision, url, oldRevision],
      );
    }
  }

  Future<Set<String>> pendingSharedTransferUrls() async => {
    for (final row in await customSelect(
      "SELECT url FROM shared_sync_outbox WHERE kind='transfer'",
    ).get())
      row.read<String>('url'),
  };

  Future<void> importRouteTransferBatch(
    Iterable<Map<String, Object?>> records,
  ) async {
    await batch((b) {
      for (final record in records) {
        if (record['transferred'] == true) {
          b.customStatement(
            'INSERT INTO channel_route_transfers VALUES(?,?,?,?,?) '
            'ON CONFLICT(url) DO UPDATE SET name=excluded.name,'
            'group_name=excluded.group_name,epg_id=excluded.epg_id,logo_url=excluded.logo_url',
            [
              record['url'],
              record['name'],
              record['group'],
              record['epgId'],
              record['logoUrl'],
            ],
          );
        } else {
          b.customStatement('DELETE FROM channel_route_transfers WHERE url=?', [
            record['url'],
          ]);
        }
      }
    });
  }

  /// Commit locally with a durable event; neither network nor decoder blocks it.
  Future<ChannelRouteTransfer> transferRoute(
    String routeUrl,
    ChannelMergeChoice destination,
  ) async {
    final url = canonicalRouteUrl(routeUrl);
    late ChannelRouteTransfer result;
    await withoutSharedReporting(() async {
      final owners = await getChannelsByStreamUrls([url]);
      final targets = await channelsForMergeChoice(destination);
      if (owners.isEmpty || targets.isEmpty)
        throw StateError('Channel no longer exists');
      if (targets.any((c) => canonicalRouteUrl(c.streamUrl) == url)) {
        throw ArgumentError('Route already belongs to this channel');
      }
      if (await isStreamUrlBlocked(url)) throw StateError('Route was retired');
      final eligible = {
        for (final p in await getAllProviders())
          if (isSharedInventoryProvider(
            id: p.id,
            type: p.type,
            url: p.url,
            username: p.username,
            password: p.password,
          ))
            p.id,
      };
      final public =
          owners.any((c) => eligible.contains(c.providerId)) &&
          BobTvApiClient.isPublicCatalogUrl(url);
      final target = targets
          .where(
            (c) =>
                c.streamUrl != url &&
                (!public ||
                    (eligible.contains(c.providerId) &&
                        BobTvApiClient.isPublicCatalogUrl(c.streamUrl))),
          )
          .firstOrNull;
      if (target == null)
        throw StateError('Public routes require a public destination');
      if (await isStreamUrlBlocked(target.streamUrl)) {
        throw StateError('Destination route was retired');
      }
      final mergeId = (await channelMergeIds([
        target.streamUrl,
      ]))[target.streamUrl];
      result = ChannelRouteTransfer(
        url: url,
        targetChannelId: target.id,
        targetUrl: target.streamUrl,
        name: target.name,
        group: target.groupTitle ?? '其他',
        epgId: target.tvgId,
        logoUrl: target.tvgLogo,
        mergeId: mergeId,
        shared: public,
      );
      await ManualChannelCategory.remove([url]);
      await importRouteTransferBatch([
        {
          'url': url,
          'name': result.name,
          'group': result.group,
          'epgId': result.epgId,
          'logoUrl': result.logoUrl,
          'transferred': true,
        },
      ]);
      await importChannelMerge({
        'url': url,
        'mergeId': mergeId,
        'name': result.name,
        'group': result.group,
        'epgId': result.epgId,
        'logoUrl': result.logoUrl,
      });
      await (update(channels)..where((c) => c.streamUrl.equals(url))).write(
        ChannelsCompanion(
          name: Value(result.name),
          groupTitle: Value(result.group),
          tvgId: Value(result.epgId),
          tvgName: Value(result.name),
          tvgLogo: Value(result.logoUrl),
        ),
      );
      await customStatement(
        "DELETE FROM shared_sync_outbox WHERE kind='classify' AND url=?",
        [url],
      );
      if (public)
        await queueSharedEvent(url, 'transfer', {
          'url': url,
          'targetUrl': result.targetUrl,
          'baseRevision': await sharedRouteRevision(url),
          'targetRevision': await sharedRouteRevision(result.targetUrl),
        });
    });
    return result;
  }

  Future<Set<String>> pendingSharedCategoryUrls() async => {
    for (final row in await customSelect(
      "SELECT DISTINCT url FROM shared_sync_outbox WHERE kind='classify'",
    ).get())
      row.read<String>('url'),
  };

  Future<Map<String, String>> channelMergeIds(Iterable<String> urls) async {
    final unique = urls.map(canonicalRouteUrl).toSet().toList();
    final result = <String, String>{};
    for (var offset = 0; offset < unique.length; offset += 300) {
      final rows = await customSelect(
        'SELECT url,merge_id FROM channel_merge_overrides WHERE url IN '
        '(SELECT value FROM json_each(?))',
        variables: [
          Variable(jsonEncode(unique.skip(offset).take(300).toList())),
        ],
      ).get();
      for (final row in rows)
        result[row.read<String>('url')] = row.read<String>('merge_id');
    }
    return result;
  }

  Future<List<String>> channelMergeGroups() async => (await customSelect(
    "SELECT DISTINCT COALESCE(group_title,'其他') AS g "
    'FROM channels ORDER BY g',
    readsFrom: {channels},
  ).get()).map((row) => row.read<String>('g')).toList();

  Future<List<ChannelMergeChoice>> searchChannelMergeChoices({
    String query = '',
    String? group,
    int offset = 0,
    int limit = 80,
    Map<String, List<Channel>>? snapshot,
  }) async {
    final members = snapshot ?? await channelMergeSnapshot();
    final queryLower = query.toLowerCase();
    final choices = <ChannelMergeChoice>[];
    for (final entry in members.entries) {
      final matches = entry.value.where((c) =>
          (group == null || (c.groupTitle ?? '其他') == group) &&
          c.name.toLowerCase().contains(queryLower)).toList();
      if (matches.isEmpty) continue;
      final first = matches.first;
      choices.add(ChannelMergeChoice(
        id: entry.value.first.id, identityKey: entry.key,
        name: first.name, group: first.groupTitle ?? '其他',
        routeCount: entry.value.map((c) => canonicalRouteUrl(c.streamUrl)).toSet().length,
      ));
    }
    choices.sort((a, b) {
      final name = a.name.compareTo(b.name);
      if (name != 0) return name;
      final category = a.group.compareTo(b.group);
      return category != 0 ? category : a.id.compareTo(b.id);
    });
    return choices.skip(offset < 0 ? 0 : offset).take(limit.clamp(1, 80)).toList();
  }

  /// An explicit picker may reuse this snapshot for search and pagination.
  /// Selected identities are read again before committing a merge or transfer.
  Future<Map<String, List<Channel>>> channelMergeSnapshot() async {
    final visible = await (select(channels)
      ..where((c) => c.hidden.equals(false))
      ..orderBy([(c) => OrderingTerm.asc(c.id)])).get();
    final keys = await channelPresentationKeys(visible);
    final result = <String, List<Channel>>{};
    for (final channel in visible) {
      (result[keys[channel.id]!] ??= []).add(channel);
    }
    return result;
  }

  Future<ChannelMergeChoice> channelMergeChoiceForChannel(Channel channel,
      {Map<String, List<Channel>>? snapshot}) async {
    final groups = snapshot ?? await channelMergeSnapshot();
    for (final entry in groups.entries) {
      if (!entry.value.any((c) => c.id == channel.id)) continue;
      return ChannelMergeChoice(
        id: entry.value.first.id, identityKey: entry.key,
        name: channel.name, group: channel.groupTitle ?? '其他',
        routeCount: entry.value.map((c) => canonicalRouteUrl(c.streamUrl)).toSet().length,
      );
    }
    throw StateError('Channel no longer exists');
  }

  Future<List<Channel>> channelsForMergeChoice(ChannelMergeChoice choice) =>
      channelsForMergeChoices([choice]);

  Future<List<Channel>> channelsForMergeChoices(Iterable<ChannelMergeChoice> choices) async {
    final groups = await channelMergeSnapshot();
    final members = <String, Channel>{};
    for (final choice in choices) {
      List<Channel>? selected;
      if (choice.mergeId != null) {
        selected = groups['manual:${choice.mergeId}'];
      } else {
        for (final entry in groups.entries) {
          if (entry.value.any((c) => c.id == choice.id) &&
              (choice.identityKey == null || choice.identityKey == entry.key)) {
            selected = entry.value;
            break;
          }
        }
      }
      if (selected == null || selected.isEmpty) {
        throw StateError('Channel changed; reopen the selection');
      }
      for (final channel in selected) { members[channel.id] = channel; }
    }
    return members.values.toList();
  }

  Future<Set<String>> pendingSharedMergeUrls() async {
    final rows = await customSelect(
      "SELECT payload FROM shared_sync_outbox WHERE kind='merge'",
    ).get();
    return {
      for (final row in rows)
        for (final route
            in (jsonDecode(row.read<String>('payload'))['routes'] as List))
          route['url'] as String,
    };
  }

  Future<void> importChannelMerge(Map<String, Object?> record) async {
    final url = record['url'] as String;
    final mergeId = record['mergeId'] as String?;
    if (mergeId == null) {
      await customStatement('DELETE FROM channel_merge_overrides WHERE url=?', [
        url,
      ]);
    } else {
      await customStatement(
        'INSERT INTO channel_merge_overrides VALUES(?,?,?,?,?,?) '
        'ON CONFLICT(url) DO UPDATE SET merge_id=excluded.merge_id,name=excluded.name,'
        'group_name=excluded.group_name,epg_id=excluded.epg_id,logo_url=excluded.logo_url',
        [
          url,
          mergeId,
          record['name'],
          record['group'],
          record['epgId'],
          record['logoUrl'],
        ],
      );
    }
  }

  Future<void> importChannelMergeBatch(
    Iterable<Map<String, Object?>> records,
  ) async {
    final rows = records.toList();
    final plain = rows
        .where((r) => r['mergeId'] == null)
        .map((r) => r['url'])
        .toList();
    if (plain.isNotEmpty)
      await customStatement(
        'DELETE FROM channel_merge_overrides WHERE url IN (SELECT value FROM json_each(?))',
        [jsonEncode(plain)],
      );
    await batch((b) {
      for (final row in rows.where((r) => r['mergeId'] != null)) {
        b.customStatement(
          'INSERT INTO channel_merge_overrides VALUES(?,?,?,?,?,?) '
          'ON CONFLICT(url) DO UPDATE SET merge_id=excluded.merge_id,name=excluded.name,'
          'group_name=excluded.group_name,epg_id=excluded.epg_id,logo_url=excluded.logo_url',
          [
            row['url'],
            row['mergeId'],
            row['name'],
            row['group'],
            row['epgId'],
            row['logoUrl'],
          ],
        );
      }
    });
  }

  Future<void> advanceQueuedMergeRevision(
    String url,
    int oldRevision,
    int revision,
  ) async {
    final rows = await customSelect(
      "SELECT id,payload FROM shared_sync_outbox WHERE kind='merge'",
    ).get();
    for (final row in rows) {
      final payload =
          jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
      var changed = false;
      for (final route in payload['routes'] as List) {
        if (route['url'] == url && route['baseRevision'] == oldRevision) {
          route['baseRevision'] = revision;
          changed = true;
        }
      }
      if (changed)
        await customStatement(
          'UPDATE shared_sync_outbox SET payload=? WHERE id=?',
          [jsonEncode(payload), row.read<String>('id')],
        );
    }
  }

  /// One local transaction plus one durable public event. No network request
  /// blocks the dialog. Endpoint identities, checks and retirement stay intact.
  Future<String> mergeChannels(ChannelMergePlan plan) async {
    if (!plan.valid) throw ArgumentError('Invalid merge plan');
    final mergeId = _uuid.v4();
    await withoutSharedReporting(() async {
      final owners = await getChannelsByStreamUrls(plan.urls);
      if (owners.isEmpty) throw StateError('Selected channels no longer exist');
      final ids = await channelMergeIds(plan.urls);
      final related = ids.values.toSet();
      final expanded = {...plan.urls};
      for (final id in related) {
        final rows = await customSelect(
          'SELECT url FROM channel_merge_overrides WHERE merge_id=?',
          variables: [Variable(id)],
        ).get();
        expanded.addAll(rows.map((row) => row.read<String>('url')));
      }
      if (expanded.length > 1000)
        throw ArgumentError('Too many routes in one merge');
      await ManualChannelCategory.remove(expanded);
      await customStatement(
        'DELETE FROM channel_route_transfers WHERE url IN (SELECT value FROM json_each(?))',
        [jsonEncode(expanded.toList())],
      );
      final providers = {
        for (final p in await getAllProviders())
          if (isSharedInventoryProvider(
            id: p.id,
            type: p.type,
            url: p.url,
            username: p.username,
            password: p.password,
          ))
            p.id,
      };
      final publicUrls = {
        for (final c in await getChannelsByStreamUrls(expanded))
          if (providers.contains(c.providerId) &&
              BobTvApiClient.isPublicCatalogUrl(c.streamUrl))
            c.streamUrl,
      };
      final event = <String, Object?>{
        'mergeId': mergeId,
        'name': plan.name,
        'group': plan.group,
        'epgId': plan.epgId,
        'logoUrl': plan.logoUrl,
        'routes': [
          for (final url in publicUrls)
            {'url': url, 'baseRevision': await sharedRouteRevision(url)},
        ],
      };
      if (utf8.encode(jsonEncode(event)).length > 400 * 1024) {
        throw ArgumentError('Merge request exceeds safe size');
      }
      for (final url in expanded) {
        await importChannelMerge({
          'url': url,
          'mergeId': mergeId,
          'name': plan.name,
          'group': plan.group,
          'epgId': plan.epgId,
          'logoUrl': plan.logoUrl,
        });
      }
      for (var offset = 0; offset < expanded.length; offset += 300) {
        await (update(channels)
              ..where((c) => c.streamUrl.isIn(expanded.skip(offset).take(300))))
            .write(
              ChannelsCompanion(
                name: Value(plan.name),
                groupTitle: Value(plan.group),
                tvgId: Value(plan.epgId),
                tvgName: Value(plan.name),
                tvgLogo: Value(plan.logoUrl),
              ),
            );
      }
      // Old classification requests for these routes must not race the merge.
      await customStatement(
        "DELETE FROM shared_sync_outbox WHERE kind='classify' "
        'AND url IN (SELECT value FROM json_each(?))',
        [jsonEncode(expanded.toList())],
      );
      if (publicUrls.isNotEmpty)
        await queueSharedEvent(publicUrls.first, 'merge', event);
    });
    return mergeId;
  }

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
    final terms = ChannelCategoryClassifier.candidateTermsForCategory(category);
    if (category != '其他' && terms == null) {
      // Explicit custom hierarchies are matched exactly. Never run the broad
      // "Other" name heuristic for a newly created category.
      return (select(channels)..where((row) =>
          row.groupTitle.equals('中国 / $category'))).get();
    }
    if (terms == null) {
      // "Other" is evaluated only when selected. SQL removes every row that
      // is an obvious member of another category before Dart sees the result.
      final allTerms = ChannelCategoryClassifier.allCategoryCandidateTerms
          // SQLite LIKE has no word-boundary operator. Do not exclude short
          // Latin tokens such as BTV here: NRBTV must remain visible in
          // "Other" until the Dart classifier can decide its category.
          .where((term) => !RegExp(r'^[a-z]{2,4}$').hasMatch(term))
          .toSet();
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
        'SELECT * FROM channels WHERE '
        '(group_title = ? OR group_title LIKE ?) OR '
        '(provider_id = ? AND (group_title IN (?, ?) OR group_title LIKE ?)) OR '
        '(provider_id != ? AND NOT (${conditions.join(' OR ')}))',
        variables: [
          Variable.withString('其他'),
          Variable.withString('其他 / %'),
          Variable.withString('bobtv-channel-catalog'),
          Variable.withString('其他'),
          Variable.withString('中国 / 其他'),
          Variable.withString('其他 / %'),
          Variable.withString('bobtv-channel-catalog'),
          ...variables,
        ],
        readsFrom: {channels},
      ).get();
      return rows.map((row) => channels.map(row.data)).toList();
    }

    final conditions = <String>[];
    final variables = <Variable<String>>[];
    for (final term in terms) {
      final pattern = '%${term.toLowerCase()}%';
      if (category == '央视') {
        conditions.add(
          '(lower(name) LIKE ? OR lower(COALESCE(tvg_id, \'\')) LIKE ? '
          'OR (provider_id = ? AND lower(COALESCE(group_title, \'\')) LIKE ?))',
        );
        variables.addAll([
          Variable.withString(pattern),
          Variable.withString(pattern),
          Variable.withString('bobtv-channel-catalog'),
          Variable.withString(pattern),
        ]);
      } else if (category == '广播') {
        conditions.add(
          '(lower(name) LIKE ? OR lower(COALESCE(group_title, \'\')) LIKE ? '
          'OR lower(COALESCE(tvg_id, \'\')) LIKE ? '
          'OR lower(stream_url) LIKE ?)',
        );
        variables.addAll([
          Variable.withString(pattern),
          Variable.withString(pattern),
          Variable.withString(pattern),
          Variable.withString(pattern),
        ]);
      } else {
        conditions.add(
          '(lower(name) LIKE ? OR lower(COALESCE(group_title, \'\')) LIKE ? '
          'OR lower(COALESCE(tvg_id, \'\')) LIKE ?)',
        );
        variables.addAll([
          Variable.withString(pattern),
          Variable.withString(pattern),
          Variable.withString(pattern),
        ]);
      }
    }
    if (category == '广播') {
      for (final extension in const ['.aac', '.mp3', '.m4a', '.ogg', '.opus']) {
        conditions.add('lower(stream_url) LIKE ?');
        variables.add(Variable.withString('%$extension%'));
      }
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
    // Website routes already carry reviewed categories. Include them by
    // category metadata so a channel name without category keywords is not
    // silently omitted from the shared list.
    final websiteGroup = category == '国际'
        ? '国际 / %'
        : ChannelCategoryClassifier.provinceCategories.contains(category)
        ? '中国 / $category / %'
        : '中国 / $category';
    final rows = await customSelect(
      'SELECT * FROM channels WHERE '
      '(provider_id = ? AND (group_title = ? OR group_title = ? '
      'OR group_title LIKE ?)) OR '
      '(provider_id != ? AND (${conditions.join(' OR ')}))',
      variables: [
        Variable.withString('bobtv-channel-catalog'),
        Variable.withString(category),
        Variable.withString('中国 / $category'),
        Variable.withString(websiteGroup),
        Variable.withString('bobtv-channel-catalog'),
        ...variables,
      ],
      readsFrom: {channels},
    ).get();
    return rows.map((row) => channels.map(row.data)).toList();
  }

  /// Reads only distinct explicit paths, without loading channel objects.
  Future<List<String>> getStructuredCategoryGroups() async {
    final rows = await customSelect(
      'SELECT DISTINCT group_title FROM channels '
      'WHERE group_title LIKE ? OR group_title LIKE ? OR group_title = ? OR group_title LIKE ? ORDER BY group_title',
      variables: [
        Variable.withString('中国 / %'),
        Variable.withString('国际 / %'),
        Variable.withString('其他'),
        Variable.withString('其他 / %'),
      ],
      readsFrom: {channels},
    ).get();
    return rows.map((row) => row.read<String>('group_title'))
        .where((group) => ChannelCategoryDestination.fromGroup(group) != null)
        .toList();
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
    await transaction(() async {
      entries = entries
          .map(
            (entry) => entry.streamUrl.present
                ? entry.copyWith(
                    streamUrl: Value(canonicalRouteUrl(entry.streamUrl.value)),
                  )
                : entry,
          )
          .toList();
      final manualCategories = await ManualChannelCategory.load();
      final blockedUrls = {
        for (final route in await select(blockedStreamRoutes).get())
          canonicalRouteUrl(route.streamUrl),
        ...(await pendingSharedRemovedUrls()).map(canonicalRouteUrl),
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
      entries = entries.map((entry) {
        final manual = entry.streamUrl.present
            ? manualCategories[entry.streamUrl.value]
            : null;
        return manual == null
            ? entry
            : entry.copyWith(groupTitle: Value(manual.group));
      }).toList();
      final transfers = {
        for (final row in await customSelect(
          'SELECT * FROM channel_route_transfers WHERE url IN (SELECT value FROM json_each(?))',
          variables: [
            Variable(
              jsonEncode(
                entries
                    .where((e) => e.streamUrl.present)
                    .map((e) => e.streamUrl.value)
                    .toList(),
              ),
            ),
          ],
        ).get())
          row.read<String>('url'): row,
      };
      entries = entries.map((entry) {
        final transfer = entry.streamUrl.present
            ? transfers[entry.streamUrl.value]
            : null;
        return transfer == null
            ? entry
            : entry.copyWith(
                name: Value(transfer.read<String>('name')),
                groupTitle: Value(transfer.read<String>('group_name')),
                tvgName: Value(transfer.read<String>('name')),
                tvgId: Value(transfer.readNullable<String>('epg_id')),
                tvgLogo: Value(transfer.readNullable<String>('logo_url')),
              );
      }).toList();
      final merges = {
        for (final row in await customSelect(
          'SELECT * FROM channel_merge_overrides WHERE url IN (SELECT value FROM json_each(?))',
          variables: [
            Variable(
              jsonEncode(
                entries
                    .where((e) => e.streamUrl.present)
                    .map((e) => e.streamUrl.value)
                    .toList(),
              ),
            ),
          ],
        ).get())
          row.read<String>('url'): row,
      };
      entries = entries.map((entry) {
        final merge = entry.streamUrl.present
            ? merges[entry.streamUrl.value]
            : null;
        return merge == null
            ? entry
            : entry.copyWith(
                name: Value(merge.read<String>('name')),
                groupTitle: Value(merge.read<String>('group_name')),
                tvgName: Value(merge.read<String>('name')),
                tvgId: Value(merge.readNullable<String>('epg_id')),
                tvgLogo: Value(merge.readNullable<String>('logo_url')),
              );
      }).toList();
      await batch((b) {
        b.insertAllOnConflictUpdate(channels, entries);
      });
      await _inheritFavoritesForIds(entries.where((e) => e.id.present).map((e) => e.id.value).toSet());
    });
  }

  Future<List<Channel>> getChannelsByStreamUrls(Iterable<String> urls) async {
    final unique = urls.toSet().toList();
    final result = <Channel>[];
    for (var offset = 0; offset < unique.length; offset += 400) {
      result.addAll(
        await (select(channels)..where(
              (row) => row.streamUrl.isIn(unique.skip(offset).take(400)),
            ))
            .get(),
      );
    }
    return result;
  }

  Future<void> setManualChannelCategory(
    Iterable<String> urls,
    ChannelCategoryDestination destination,
  ) async {
    final unique = urls.where((url) => url.isNotEmpty).toSet().toList();
    await withoutSharedReporting(() async {
      await ManualChannelCategory.save(unique, destination);
      for (var offset = 0; offset < unique.length; offset += 400) {
        await (update(channels)..where(
              (row) => row.streamUrl.isIn(unique.skip(offset).take(400)),
            ))
            .write(ChannelsCompanion(groupTitle: Value(destination.group)));
      }
      for (final url in unique) {
        await customStatement(
          'UPDATE channel_merge_overrides SET group_name=? WHERE url=?',
          [destination.group, url],
        );
        await customStatement(
          'UPDATE channel_route_transfers SET group_name=? WHERE url=?',
          [destination.group, url],
        );
        await queueSharedEvent(url, 'classify', {
          'group': destination.group,
          'baseRevision': await sharedRouteRevision(url),
        });
      }
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
    final owner = await (select(
      channels,
    )..where((table) => table.id.equals(channelId))).getSingleOrNull();
    if (owner == null) return 0;
    return blockAndDeleteStreamUrl(
      streamUrl,
      reason: 'static_advertising_frame',
    );
  }

  /// Rejects one endpoint and all equivalent URL spellings across providers.
  Future<int> blockAndDeleteStreamUrl(
    String streamUrl, {
    required String reason,
  }) async {
    return transaction(() async {
      streamUrl = canonicalRouteUrl(streamUrl);
      // Legacy spellings are checked only during this explicit retirement action.
      // Read IDs/URLs/provider IDs, without materializing full channel metadata.
      final rows =
          await (selectOnly(channels)..addColumns([
                channels.id,
                channels.streamUrl,
                channels.providerId,
              ]))
              .get();
      final matches = rows
          .where(
            (row) =>
                canonicalRouteUrl(row.read(channels.streamUrl)!) == streamUrl,
          )
          .toList();
      final previous = (await select(blockedStreamRoutes).get())
          .where((route) => canonicalRouteUrl(route.streamUrl) == streamUrl)
          .firstOrNull;
      final publicProviders = {
        for (final provider in await getAllProviders())
          if (isSharedInventoryProvider(
            id: provider.id,
            type: provider.type,
            url: provider.url,
            username: provider.username,
            password: provider.password,
          ))
            provider.id,
      };
      final shared =
          reason == 'shared_catalog_retired' ||
          (previous != null && !previous.reason.startsWith('private:')) ||
          matches.any(
            (row) => publicProviders.contains(row.read(channels.providerId)),
          );
      await into(blockedStreamRoutes).insertOnConflictUpdate(
        BlockedStreamRoutesCompanion.insert(
          streamUrl: streamUrl,
          reason: shared ? reason : 'private:$reason',
        ),
      );
      return deleteChannelsByIds(matches.map((row) => row.read(channels.id)!));
    });
  }

  Future<bool> isStreamUrlBlocked(String streamUrl) async =>
      (await getBlockedStreamUrls()).contains(canonicalRouteUrl(streamUrl));

  Future<Set<String>> getBlockedStreamUrls() async => {
    for (final route in await select(blockedStreamRoutes).get())
      canonicalRouteUrl(route.streamUrl),
  };

  Future<Set<String>> getSharedBlockedStreamUrls() async => {
    for (final route in await select(blockedStreamRoutes).get())
      if (!route.reason.startsWith('private:'))
        canonicalRouteUrl(route.streamUrl),
  };

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

  /// A catalog migration can rename route IDs while keeping the same URL.
  /// Copy user references before the old channel is removed by the importer.
  Future<void> copyChannelReferences(String oldId, String newId) async {
    if (oldId == newId) return;
    final favorites = await (select(
      favoriteListChannels,
    )..where((row) => row.channelId.equals(oldId))).get();
    for (final row in favorites) {
      await into(favoriteListChannels).insert(
        row.toCompanion(false).copyWith(channelId: Value(newId)),
        mode: InsertMode.insertOrIgnore,
      );
    }
    final groups = await (select(
      failoverGroupChannels,
    )..where((row) => row.channelId.equals(oldId))).get();
    for (final row in groups) {
      await into(failoverGroupChannels).insert(
        row.toCompanion(false).copyWith(channelId: Value(newId)),
        mode: InsertMode.insertOrIgnore,
      );
    }
    final mappings = await (select(
      epgMappings,
    )..where((row) => row.channelId.equals(oldId))).get();
    for (final row in mappings) {
      await into(epgMappings).insert(
        row.toCompanion(false).copyWith(channelId: Value(newId)),
        mode: InsertMode.insertOrIgnore,
      );
    }
  }

  Future<List<StreamCheck>> getAllStreamChecks() => select(streamChecks).get();

  /// Availability checks belong to the current network. Explicit blocks,
  /// channel identities and favorites are stored separately and stay intact.
  Future<bool> switchAvailabilityNetwork(String networkId) async {
    if (networkId.startsWith('ZZ:')) return false;
    return transaction(() async {
      await customStatement(
        'CREATE TABLE IF NOT EXISTS route_availability_network(id INTEGER PRIMARY KEY, network_id TEXT NOT NULL)',
      );
      final rows = await customSelect(
        'SELECT network_id FROM route_availability_network WHERE id=1',
      ).get();
      if (rows.isNotEmpty &&
          rows.single.read<String>('network_id') == networkId)
        return false;
      await delete(streamChecks).go();
      await customStatement(
        'INSERT INTO route_availability_network VALUES(1,?) ON CONFLICT(id) DO UPDATE SET network_id=excluded.network_id',
        [networkId],
      );
      return true;
    });
  }

  /// Fetch availability for the active category without loading the entire
  /// maintenance history into the UI isolate.
  Future<List<StreamCheck>> getStreamChecksForChannels(
    List<Channel> activeChannels,
  ) async {
    final urls = activeChannels
        .map((channel) => channel.streamUrl)
        .toSet()
        .toList();
    final checks = <StreamCheck>[];
    for (var offset = 0; offset < urls.length; offset += 300) {
      final end = (offset + 300).clamp(0, urls.length);
      checks.addAll(
        await (select(
          streamChecks,
        )..where((row) => row.streamUrl.isIn(urls.sublist(offset, end)))).get(),
      );
    }
    return checks;
  }

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

  /// Return the current programme and the next few entries for one exact EPG ID.
  /// A current film can have started hours ago. Overlapping guide entries must
  /// not consume the limited slots intended for upcoming programmes.
  Future<List<EpgProgramme>> getUpcomingProgrammes({
    required String epgChannelId,
    required DateTime at,
    int limit = 3,
  }) async {
    if (epgChannelId.isEmpty || limit <= 0) return [];
    final count = limit.clamp(1, 20);
    final current =
        await (select(epgProgrammes)
              ..where(
                (t) =>
                    t.epgChannelId.equals(epgChannelId) &
                    t.start.isSmallerOrEqualValue(at) &
                    t.stop.isBiggerThanValue(at),
              )
              ..orderBy([
                (t) => OrderingTerm.desc(t.start),
                (t) => OrderingTerm.desc(t.id),
              ])
              ..limit(1))
            .getSingleOrNull();
    if (current != null && count == 1) return [current];
    final upcoming =
        await (select(epgProgrammes)
              ..where(
                (t) =>
                    t.epgChannelId.equals(epgChannelId) &
                    t.start.isBiggerThanValue(at) &
                    t.stop.isBiggerThanValue(at),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.start)])
              ..limit(count - (current == null ? 0 : 1)))
            .get();
    return current == null ? upcoming : [current, ...upcoming];
  }

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

  Future<List<Channel>> getChannelInventoryPage(
    String afterId, {
    int limit = 200,
  }) =>
      (select(channels)
            ..where((table) => table.id.isBiggerThanValue(afterId))
            ..orderBy([(table) => OrderingTerm.asc(table.id)])
            ..limit(limit))
          .get();

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

  /// Transaction-safe invalidation; never loads the full programme table.
  Stream<void> watchEpgChanges() => tableUpdates(
    TableUpdateQuery.onAllTables([
      epgSources,
      epgChannels,
      epgProgrammes,
      epgMappings,
    ]),
  ).map((_) {});

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
      if (m.source == 'auto' || m.source == 'manual' || m.source == 'server') {
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
    await reconcileFavoriteMemberships();
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

  /// Shared by cards, route counts and favorite membership on every platform.
  /// Looking up an exact URL can bridge a legacy row even when its public row
  /// is outside the active category or has not itself been favorited.
  Future<Map<String, String>> channelPresentationKeys(
    Iterable<Channel> selected,
  ) async {
    final routes = {for (final route in selected) route.id: route};
    final urls = routes.values.map((c) => canonicalRouteUrl(c.streamUrl)).toSet().toList();
    for (var offset = 0; offset < urls.length; offset += 300) {
      final rows = await (select(channels)..where((c) =>
          c.providerId.equals('bobtv-channel-catalog') &
          c.streamUrl.isIn(urls.skip(offset).take(300)))).get();
      for (final route in rows) { routes[route.id] = route; }
    }
    // Resolve the full authoritative service before assigning presentation keys.
    // Category/favorite queries may contain only one of its route labels.
    final selectedCatalogIds = await publicCatalogChannelIds(routes.values
        .where((c) => c.providerId == 'bobtv-channel-catalog').map((c) => c.id));
    final identities = selectedCatalogIds.values.toSet().toList();
    for (var offset = 0; offset < identities.length; offset += 400) {
      final page = identities.skip(offset).take(400).toList();
      final rows = await customSelect(
        'SELECT c.* FROM channels c JOIN catalog_epg_routes r '
        'ON r.local_channel_id=c.id WHERE c.provider_id=? '
        'AND r.catalog_channel_id IN (SELECT value FROM json_each(?))',
        variables: [Variable('bobtv-channel-catalog'), Variable(jsonEncode(page))],
      ).get();
      for (final row in rows) {
        final route = channels.map(row.data);
        routes[route.id] = route;
      }
    }
    final catalogIds = await publicCatalogChannelIds(routes.values
        .where((c) => c.providerId == 'bobtv-channel-catalog').map((c) => c.id));
    final context = <String, QueryRow>{};
    final publicIds = catalogIds.keys.toList();
    for (var offset = 0; offset < publicIds.length; offset += 400) {
      final page = publicIds.skip(offset).take(400).toList();
      final rows = await customSelect(
        'SELECT * FROM catalog_presentation_context WHERE local_channel_id IN '
        '(SELECT value FROM json_each(?))',
        variables: [Variable(jsonEncode(page))],
      ).get();
      for (final row in rows) { context[row.read<String>('local_channel_id')] = row; }
    }
    final mergeIds = await channelMergeIds(routes.values.map((c) => c.streamUrl));
    return ChannelPresentationIdentity.keys(routes.values.map((c) =>
      ChannelPresentationRoute(id: c.id, name: c.name, url: c.streamUrl,
        group: c.groupTitle, tvgName: c.tvgName, tvgId: c.tvgId,
        countryCode: context[c.id]?.readNullable<String>('country_code'),
        regionCode: context[c.id]?.readNullable<String>('region_code'),
        mergeId: mergeIds[canonicalRouteUrl(c.streamUrl)],
        catalogId: c.providerId == 'bobtv-channel-catalog'
            ? catalogIds[c.id] ?? c.id : null)));
  }

  Future<Set<String>> _favoriteEquivalentIds(String channelId) async {
    final selected = await (select(channels)..where((c) => c.id.equals(channelId))).getSingleOrNull();
    if (selected == null) return {};
    final all = await select(channels).get();
    final keys = await channelPresentationKeys(all);
    final key = keys[channelId];
    final blocked = await getBlockedStreamUrls();
    // Explicit favorite actions can search all providers and classifications.
    // This is not a background stream probe or whole-catalog media scan.
    return {for (final c in all)
      if (keys[c.id] == key &&
          !blocked.contains(canonicalRouteUrl(c.streamUrl))) c.id};
  }

  Future<void> addChannelToList(String listId, String channelId) async {
    final ids = await _favoriteEquivalentIds(channelId);
    await batch((b) {
      for (final id in ids) {
        b.insert(favoriteListChannels, FavoriteListChannelsCompanion.insert(
            listId: listId, channelId: id), mode: InsertMode.insertOrIgnore);
      }
    });
  }

  Future<void> _inheritFavoritesForIds(Set<String> ids) async {
    if (ids.isEmpty) return;
    final members = await select(favoriteListChannels).get();
    if (members.isEmpty) return;
    final anchors = {for (final c in await getChannelsByIds(members.map((m) => m.channelId).toSet())) c.id: c};
    final newRoutes = await getChannelsByIds(ids);
    final keys = await channelPresentationKeys([...anchors.values, ...newRoutes]);
    final listsByKey = <String, Set<String>>{};
    for (final member in members) {
      final anchor = anchors[member.channelId];
      if (anchor != null) (listsByKey[keys[anchor.id]!] ??= {}).add(member.listId);
    }
    await batch((b) {
      for (final route in newRoutes) {
        for (final list in listsByKey[keys[route.id]] ?? <String>{}) {
          b.insert(favoriteListChannels, FavoriteListChannelsCompanion.insert(
              listId: list, channelId: route.id), mode: InsertMode.insertOrIgnore);
        }
      }
    });
  }

  Future<void> reconcileFavoriteMemberships({bool force = false}) {
    if (_favoriteExpansionDone && !force) return Future.value();
    return _favoriteExpansion ??= (() async {
      final members = await select(favoriteListChannels).get();
      if (members.isNotEmpty) {
        final ids = (await (selectOnly(channels)..addColumns([channels.id])).get())
            .map((r) => r.read(channels.id)!).toSet();
        await _inheritFavoritesForIds(ids);
      }
      _favoriteExpansionDone = true;
    })().whenComplete(() { _favoriteExpansion = null; });
  }

  /// A single click on the favorite star must persist even when the user has
  /// not created any named lists yet. Keep the default list's ID stable so
  /// concurrent clicks cannot create duplicate lists.
  Future<List<FavoriteList>> addChannelToDefaultFavorites(
    String channelId,
  ) async {
    await into(favoriteLists).insert(
      FavoriteListsCompanion.insert(id: 'default', name: '我的收藏'),
      mode: InsertMode.insertOrIgnore,
    );
    await addChannelToList('default', channelId);
    return getAllFavoriteLists();
  }

  Future<void> removeChannelFromList(String listId, String channelId) async {
    final ids = await _favoriteEquivalentIds(channelId);
    if (ids.isEmpty) ids.add(channelId);
    for (var offset = 0; offset < ids.length; offset += 400) {
      await (delete(favoriteListChannels)..where((t) =>
          t.listId.equals(listId) & t.channelId.isIn(ids.skip(offset).take(400)))).go();
    }
  }

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
    await reconcileFavoriteMemberships();
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

class _DatabaseWorker {
  ReceivePort? _exitPort;
  Future<dynamic>? _exited;

  SendPort observeExit() {
    final port = _exitPort = ReceivePort('BobTV SQLite shutdown');
    _exited = port.first;
    return port.sendPort;
  }

  Future<void> waitForExit() async {
    if (_exited == null) return; // The lazy connection was never opened.
    try {
      await _exited;
    } finally {
      _exitPort?.close();
    }
  }
}

// A separate closure scope keeps the ReceivePort and database off the message
// sent to the worker. Only the SendPort crosses the isolate boundary.
void Function() _observeDatabaseExit(SendPort port) =>
    () => Isolate.current.addOnExitListener(port);

LazyDatabase _openConnection(_DatabaseWorker worker) {
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

    return NativeDatabase.createInBackground(
      file,
      isolateSetup: _observeDatabaseExit(worker.observeExit()),
    );
  });
}

/// Lightweight struct for failover group membership lookups.
class FailoverGroupMembership {
  final FailoverGroup group;
  final int priority;
  const FailoverGroupMembership({required this.group, required this.priority});
}
