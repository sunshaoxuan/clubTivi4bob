import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;

import '../datasources/local/database.dart' as db;
import '../models/device_favorites_snapshot.dart';
import 'route_identity.dart';

String favoriteRouteKey(String url) =>
    sha256.convert(utf8.encode(canonicalRouteUrl(url))).toString();
String favoriteSnapshotDigest(DeviceFavoritesSnapshot snapshot) =>
    sha256.convert(utf8.encode(jsonEncode(snapshot.toJson()))).toString();

class DeviceFavoritesLocal {
  const DeviceFavoritesLocal({
    required this.revision,
    required this.acknowledged,
    required this.remoteRevision,
    required this.initialized,
    required this.digest,
    required this.snapshot,
  });
  final int revision, acknowledged, remoteRevision;
  final bool initialized;
  final String? digest;
  final DeviceFavoritesSnapshot snapshot;
}

/// Local transactional bookkeeping. The secret never enters this database.
class DeviceFavoritesStore {
  DeviceFavoritesStore(this.database);
  final db.AppDatabase database;
  Future<void>? _initializing;
  bool _initialized = false;
  Future<void> initialize() => _initialized
      ? Future.value()
      : _initializing ??= _initialize()
            .then((_) => _initialized = true)
            .then<void>((_) {})
            .whenComplete(() => _initializing = null);
  String? _lastPending;
  String? _lastCatalog;
  int? _lastChannelCount;
  DateTime? _lastResolve;

  Future<void> _initialize() async {
    await database.customStatement(
      'CREATE TABLE IF NOT EXISTS private_favorites_state(id INTEGER PRIMARY KEY CHECK(id=1), owner TEXT, revision INTEGER NOT NULL DEFAULT 0, acknowledged INTEGER NOT NULL DEFAULT -1, remote_revision INTEGER NOT NULL DEFAULT 0, initialized INTEGER NOT NULL DEFAULT 0, digest TEXT, suppressed INTEGER NOT NULL DEFAULT 0)',
    );
    await database.customStatement(
      'INSERT OR IGNORE INTO private_favorites_state(id) VALUES(1)',
    );
    await database.customStatement(
      'CREATE TABLE IF NOT EXISTS private_favorites_pending(scope TEXT NOT NULL,route_key TEXT NOT NULL,ordinal INTEGER NOT NULL,PRIMARY KEY(scope,route_key))',
    );
    for (final table in ['favorite_lists', 'favorite_list_channels']) {
      for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
        final removePending = table == 'favorite_lists' && operation == 'DELETE'
            ? "DELETE FROM private_favorites_pending WHERE scope='list:'||OLD.id;"
            : '';
        await database.customStatement(
          'CREATE TRIGGER IF NOT EXISTS private_${table}_${operation.toLowerCase()} AFTER $operation ON $table WHEN (SELECT suppressed FROM private_favorites_state WHERE id=1)=0 BEGIN UPDATE private_favorites_state SET revision=revision+1 WHERE id=1; $removePending END',
        );
      }
    }
    await database.customStatement(
      'CREATE TRIGGER IF NOT EXISTS private_legacy_favorite_update AFTER UPDATE ON channels WHEN OLD.favorite IS NOT NEW.favorite AND (SELECT suppressed FROM private_favorites_state WHERE id=1)=0 BEGIN UPDATE private_favorites_state SET revision=revision+1 WHERE id=1; END',
    );
  }

  Future<void> bindOwner(String owner) async {
    await initialize();
    await database.transaction(() async {
      final previous =
          (await database
                  .customSelect(
                    'SELECT owner FROM private_favorites_state WHERE id=1',
                  )
                  .getSingle())
              .readNullable<String>('owner');
      if (previous == owner) return;
      if (previous != null) {
        await database.customStatement('DELETE FROM private_favorites_pending');
      }
      await database.customStatement(
        'UPDATE private_favorites_state SET owner=?, acknowledged=-1,remote_revision=0,initialized=0,digest=NULL WHERE id=1',
        [owner],
      );
    });
  }

  Future<DeviceFavoritesLocal> read() => database.transaction(() async {
    final state = await database
        .customSelect('SELECT * FROM private_favorites_state WHERE id=1')
        .getSingle();
    final lists = await database.getAllFavoriteLists();
    lists.sort(
      (a, b) => a.sortOrder != b.sortOrder
          ? a.sortOrder.compareTo(b.sortOrder)
          : a.id.compareTo(b.id),
    );
    final members = await database
        .customSelect(
          'SELECT f.list_id,f.sort_order,c.stream_url FROM favorite_list_channels f JOIN channels c ON c.id=f.channel_id ORDER BY f.sort_order,c.id',
        )
        .get();
    final pending = await database
        .customSelect('SELECT * FROM private_favorites_pending')
        .get();
    final routeOrders = <String, Map<String, int>>{};
    for (final row in pending) {
      (routeOrders[row.read<String>('scope')] ??= {})[row.read<String>(
        'route_key',
      )] = row.read<int>(
        'ordinal',
      );
    }
    for (final row in members) {
      (routeOrders['list:${row.read<String>('list_id')}'] ??=
          {})[favoriteRouteKey(row.read<String>('stream_url'))] = row.read<int>(
        'sort_order',
      );
    }
    List<String> ordered(String scope) {
      final entries = (routeOrders[scope] ?? {}).entries.toList()
        ..sort(
          (a, b) => a.value != b.value
              ? a.value.compareTo(b.value)
              : a.key.compareTo(b.key),
        );
      return entries.map((e) => e.key).toList();
    }

    final legacy = (routeOrders['legacy'] ?? {}).keys.toSet();
    for (final channel in await database.getFavoriteChannels()) {
      legacy.add(favoriteRouteKey(channel.streamUrl));
    }
    final snapshot = DeviceFavoritesSnapshot.parse(
      DeviceFavoritesSnapshot(
        lists: [
          for (final list in lists)
            DeviceFavoriteList(
              id: list.id,
              name: list.name,
              icon: list.icon,
              sortOrder: list.sortOrder,
              routes: ordered('list:${list.id}'),
            ),
        ],
        legacyRoutes: legacy.toList()..sort(),
      ).toJson(),
    );
    return DeviceFavoritesLocal(
      revision: state.read<int>('revision'),
      acknowledged: state.read<int>('acknowledged'),
      remoteRevision: state.read<int>('remote_revision'),
      initialized: state.read<int>('initialized') == 1,
      digest: state.readNullable<String>('digest'),
      snapshot: snapshot,
    );
  });

  Future<void> acknowledge(
    String owner,
    DeviceFavoritesLocal captured,
    int remoteRevision,
  ) => database.customStatement(
    'UPDATE private_favorites_state SET acknowledged=?,remote_revision=?,initialized=1,digest=? WHERE id=1 AND owner=?',
    [
      captured.revision,
      remoteRevision,
      favoriteSnapshotDigest(captured.snapshot),
      owner,
    ],
  );

  Future<bool> restore(
    DeviceFavoritesSnapshot snapshot, {
    required String owner,
    required int expectedRevision,
    required int remoteRevision,
  }) => database.transaction(() async {
    final state = await database
        .customSelect(
          'SELECT owner,revision FROM private_favorites_state WHERE id=1',
        )
        .getSingle();
    if (state.readNullable<String>('owner') != owner ||
        state.read<int>('revision') != expectedRevision) {
      return false;
    }
    await _withoutReporting(() async {
      await database.delete(database.favoriteListChannels).go();
      await database.delete(database.favoriteLists).go();
      await (database.update(database.channels)
            ..where((t) => t.favorite.equals(true)))
          .write(const db.ChannelsCompanion(favorite: Value(false)));
      await database.customStatement('DELETE FROM private_favorites_pending');
      for (final list in snapshot.lists) {
        await database
            .into(database.favoriteLists)
            .insert(
              db.FavoriteListsCompanion.insert(
                id: list.id,
                name: list.name,
                icon: Value(list.icon),
                sortOrder: Value(list.sortOrder),
              ),
            );
        for (var i = 0; i < list.routes.length; i++) {
          await database.customStatement(
            'INSERT INTO private_favorites_pending VALUES(?,?,?)',
            ['list:${list.id}', list.routes[i], i],
          );
        }
      }
      for (var i = 0; i < snapshot.legacyRoutes.length; i++) {
        await database.customStatement(
          'INSERT INTO private_favorites_pending VALUES(?,?,?)',
          ['legacy', snapshot.legacyRoutes[i], i],
        );
      }
    });
    await resolvePending();
    final captured = await read();
    await acknowledge(owner, captured, remoteRevision);
    return true;
  });

  Future<void> _withoutReporting(Future<void> Function() action) async {
    await database.customStatement(
      'UPDATE private_favorites_state SET suppressed=suppressed+1 WHERE id=1',
    );
    try {
      await action();
    } finally {
      await database.customStatement(
        'UPDATE private_favorites_state SET suppressed=suppressed-1 WHERE id=1',
      );
    }
  }

  /// Resolve only existing local routes, without inserting a channel or reviving
  /// an unavailable/retired route. Unresolved selections survive catalog loading.
  Future<void> resolvePending() => database.transaction(() async {
    final pending = await database
        .customSelect(
          'SELECT * FROM private_favorites_pending ORDER BY scope,ordinal',
        )
        .get();
    if (pending.isEmpty) return;
    final pendingKey = jsonEncode(pending.map((row) => row.data).toList());
    final catalog = await database.sharedCatalogVersion();
    final count =
        (await database
                .customSelect('SELECT count(*) AS count FROM channels')
                .getSingle())
            .read<int>('count');
    if (pendingKey == _lastPending &&
        catalog == _lastCatalog &&
        count == _lastChannelCount &&
        _lastResolve != null &&
        DateTime.now().difference(_lastResolve!) < const Duration(minutes: 5)) {
      return;
    }
    _lastPending = pendingKey;
    _lastCatalog = catalog;
    _lastChannelCount = count;
    _lastResolve = DateTime.now();
    final blocked = await database.getBlockedStreamUrls();
    final channels = await database.getAllChannels();
    final listIds = (await database.getAllFavoriteLists())
        .map((list) => list.id)
        .toSet();
    channels.sort(
      (a, b) =>
          a.providerId == 'bobtv-channel-catalog' &&
              b.providerId != 'bobtv-channel-catalog'
          ? -1
          : b.providerId == 'bobtv-channel-catalog' &&
                a.providerId != 'bobtv-channel-catalog'
          ? 1
          : a.id.compareTo(b.id),
    );
    final byKey = <String, db.Channel>{};
    for (final channel in channels) {
      if (!blocked.contains(canonicalRouteUrl(channel.streamUrl))) {
        byKey.putIfAbsent(favoriteRouteKey(channel.streamUrl), () => channel);
      }
    }
    await _withoutReporting(() async {
      for (final row in pending) {
        final channel = byKey[row.read<String>('route_key')];
        if (channel == null) continue;
        final scope = row.read<String>('scope');
        if (scope == 'legacy') {
          await (database.update(database.channels)
                ..where((t) => t.id.equals(channel.id)))
              .write(const db.ChannelsCompanion(favorite: Value(true)));
        } else {
          final listId = scope.substring(5);
          if (!listIds.contains(listId)) continue;
          await database
              .into(database.favoriteListChannels)
              .insertOnConflictUpdate(
                db.FavoriteListChannelsCompanion.insert(
                  listId: listId,
                  channelId: channel.id,
                  sortOrder: Value(row.read<int>('ordinal')),
                ),
              );
        }
        await database.customStatement(
          'DELETE FROM private_favorites_pending WHERE scope=? AND route_key=?',
          [scope, row.read<String>('route_key')],
        );
      }
    });
  });
}
