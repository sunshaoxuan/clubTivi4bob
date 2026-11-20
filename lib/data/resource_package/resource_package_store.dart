import 'dart:convert';
import 'package:drift/drift.dart';

import '../datasources/local/database.dart' as db;
import 'resource_package.dart';

class ResourcePackageStore {
  ResourcePackageStore(this.database);
  final db.AppDatabase database;

  Future<void> remove(String providerId) => database.transaction(() async {
    final rows = await database.getChannelsForProvider(providerId);
    final origins = await database.getAllProviderOrigins();
    final origin = origins.where((o) => o.providerId == providerId).firstOrNull;
    final metadata = origin?.lastVersion == null
        ? null
        : jsonDecode(origin!.lastVersion!) as Map;
    await database.deleteChannelsByIds(rows.map((c) => c.id));
    for (final id
        in (metadata?['ownedEpgSourceIds'] as List? ??
            metadata?['epgSourceIds'] as List? ??
            const [])) {
      await (database.delete(
        database.epgMappings,
      )..where((t) => t.epgSourceId.equals(id as String))).go();
      await database.deleteEpgSource(id as String);
    }
    await (database.delete(
      database.providerOrigins,
    )..where((t) => t.providerId.equals(providerId))).go();
    await database.deleteProvider(providerId);
  });

  Future<int> apply({
    required String providerId,
    required ResourcePackage package,
    required String address,
    required bool create,
  }) async {
    return database.transaction(() async {
      final providers = await database.getAllProviders();
      final found = providers.where((p) => p.id == providerId).firstOrNull;
      if (create && found != null) throw StateError('Source already exists');
      if (!create &&
          (found == null || found.type != 'resource' || found.url != address)) {
        throw StateError('Source changed during download');
      }
      // A subscription cannot silently switch publisher identity.
      final origins = await database.getAllProviderOrigins();
      final origin = origins
          .where((p) => p.providerId == providerId)
          .firstOrNull;
      final metadata = origin?.lastVersion == null
          ? <String, dynamic>{}
          : jsonDecode(origin!.lastVersion!) as Map;
      if (metadata.isNotEmpty && metadata['id'] != package.id) {
        throw const FormatException('Resource package identity changed');
      }
      if (create) {
        await database.upsertProvider(
          db.ProvidersCompanion.insert(
            id: providerId,
            name: package.name,
            type: 'resource',
            url: Value(address.isEmpty ? null : address),
          ),
        );
      }
      final existing = {
        for (final c in await database.getChannelsForProvider(providerId))
          c.id: c,
      };
      final active = <String>{};
      final previousEpg = (metadata['epgSourceIds'] as List? ?? const [])
          .cast<String>()
          .toSet();
      final nextEpg = package.epgSources.keys
          .map((key) => ResourcePackage.localId(providerId, 'epg', key))
          .toSet();
      final ownedEpg = {
        ...(metadata['ownedEpgSourceIds'] as List? ?? previousEpg.toList())
            .cast<String>(),
        ...nextEpg,
      };
      for (final id in previousEpg.difference(nextEpg)) {
        await (database.update(database.epgSources)
              ..where((t) => t.id.equals(id)))
            .write(const db.EpgSourcesCompanion(enabled: Value(false)));
      }
      for (final epg in package.epgSources.entries) {
        await database.upsertEpgSource(
          db.EpgSourcesCompanion.insert(
            id: ResourcePackage.localId(providerId, 'epg', epg.key),
            name: '${package.name} / ${epg.key}',
            url: epg.value.toString(),
            enabled:
                previousEpg.contains(
                  ResourcePackage.localId(providerId, 'epg', epg.key),
                )
                ? const Value.absent()
                : const Value(true),
          ),
        );
      }
      for (final c in package.channels) {
        for (final route in c.routes.entries) {
          final id =
              '${ResourcePackage.localId(providerId, 'channel', c.id)}:${ResourcePackage.localId(providerId, 'route', route.key).substring(5)}';
          active.add(id);
          final saved = existing[id];
          // User sources retain their declared categories. Central catalog
          // exclusions and blocked-route votes do not apply to private sources.
          await database
              .into(database.channels)
              .insertOnConflictUpdate(
                db.ChannelsCompanion.insert(
                  id: id,
                  providerId: providerId,
                  name: c.name,
                  tvgId: Value(c.epgChannelId),
                  tvgLogo: Value(c.logo?.toString()),
                  groupTitle: Value(c.group),
                  streamUrl: route.value.toString(),
                  favorite: Value(saved?.favorite ?? false),
                  hidden: Value(saved?.hidden ?? false),
                  sortOrder: Value(saved?.sortOrder ?? 0),
                ),
              );
          if (c.epgSourceId != null) {
            final previous =
                await (database.select(database.epgMappings)..where(
                      (t) =>
                          t.channelId.equals(id) &
                          t.providerId.equals(providerId),
                    ))
                    .getSingleOrNull();
            if (previous?.locked != true) {
              await database
                  .into(database.epgMappings)
                  .insertOnConflictUpdate(
                    db.EpgMappingsCompanion.insert(
                      channelId: id,
                      providerId: providerId,
                      epgChannelId: c.epgChannelId!,
                      epgSourceId: ResourcePackage.localId(
                        providerId,
                        'epg',
                        c.epgSourceId!,
                      ),
                      confidence: const Value(1),
                      source: const Value('resource'),
                    ),
                  );
            }
          } else {
            await (database.delete(database.epgMappings)..where(
                  (t) =>
                      t.channelId.equals(id) &
                      t.providerId.equals(providerId) &
                      t.source.equals('resource') &
                      t.locked.equals(false),
                ))
                .go();
          }
        }
      }
      final listRefs =
          (await database.select(database.favoriteListChannels).get())
              .map((r) => r.channelId)
              .toSet();
      final removed = <String>[];
      for (final old in existing.values.where((c) => !active.contains(c.id))) {
        if (old.favorite || listRefs.contains(old.id)) {
          await (database.update(
            database.channels,
          )..where((t) => t.id.equals(old.id))).write(
            db.ChannelsCompanion(
              streamUrl: const Value(''),
              name: Value(
                "${old.name.replaceAll(' [source removed]', '')} [source removed]",
              ),
            ),
          );
        } else {
          removed.add(old.id);
        }
      }
      await database.deleteChannelsByIds(removed);
      await database.upsertProviderOrigin(
        db.ProviderOriginsCompanion.insert(
          providerId: providerId,
          sourceUrl: address,
          // Generic origin metadata, reused without a schema migration.
          lastVersion: Value(
            jsonEncode({
              'id': package.id,
              'revision': package.revision,
              'ownedEpgSourceIds': ownedEpg.toList(),
              'epgSourceIds': package.epgSources.keys
                  .map((key) => ResourcePackage.localId(providerId, 'epg', key))
                  .toList(),
            }),
          ),
          lastCheckedAt: Value(DateTime.now()),
          lastChangedAt: Value(DateTime.now()),
        ),
      );
      await database.markProviderRefreshed(providerId, DateTime.now());
      return active.length;
    });
  }
}
