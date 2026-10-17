import 'dart:convert';
import 'package:drift/drift.dart';

import '../datasources/local/database.dart' as db;
import '../models/catalog_epg_identity.dart';
import '../models/server_epg_snapshot.dart';

/// Only exact, reviewed public catalog identities may select the managed guide.
class ServerEpgBinding {
  ServerEpgBinding(this.database);
  final db.AppDatabase database;

  Future<String?> catalogIdentityVersion() async =>
      (await database
              .customSelect(
                'SELECT version FROM catalog_epg_identity_version WHERE id=1',
              )
              .getSingleOrNull())
          ?.read<String>('version');

  /// Called within the same transaction as a public-catalog import.
  Future<void> replaceCatalogIdentities(
    String version,
    List<Map<String, Object?>> records,
  ) async {
    await database.customStatement('DELETE FROM catalog_epg_routes');
    await database.batch((batch) {
      for (final row in records) {
        batch.customStatement(
          'INSERT INTO catalog_epg_routes VALUES(?,?,?,?,?,?)',
          [
            '$publicCatalogProviderId:${row['routeId']}',
            row['catalogChannelId'],
            row['catalogIdentityHash'],
            row['name'],
            row['epgId'],
            row['group'],
          ],
        );
      }
    });
    await database.customStatement(
      'INSERT OR REPLACE INTO catalog_epg_identity_version VALUES(1,?)',
      [version],
    );
  }

  /// This operation is local only and never uploads favorites or private URLs.
  /// All manual/locked mappings and mappings to other sources are preserved.
  Future<int> reconcile() => database.transaction(() async {
    final owned =
        await (database.select(database.epgMappings)..where(
              (row) =>
                  row.epgSourceId.equals(serverEpgSourceId) &
                  row.providerId.equals(publicCatalogProviderId) &
                  row.source.equals('server') &
                  row.locked.equals(false),
            ))
            .get();
    final previous = {for (final mapping in owned) mapping.channelId: mapping};
    final source = (await database.getAllEpgSources())
        .where((s) => s.id == serverEpgSourceId)
        .firstOrNull;
    final usable =
        source != null && source.enabled && source.url == serverEpgManifestUrl;
    final rows = !usable
        ? <QueryRow>[]
        : await database
              .customSelect(
                '''
      SELECT r.local_channel_id,r.catalog_channel_id,r.identity_hash,
        e.id AS local_epg_channel_id,
        r.name AS catalog_name,r.epg_id AS catalog_epg_id,r.group_name,
        c.name,c.tvg_id,c.group_title,i.metadata,
        m.channel_id AS mapped_channel,m.epg_source_id AS mapped_source,
        m.source AS mapping_kind,m.locked AS mapping_locked
      FROM catalog_epg_routes r JOIN channels c ON c.id=r.local_channel_id
      JOIN server_epg_identities i ON i.channel_id=r.catalog_channel_id
      JOIN epg_channels e ON e.channel_id=r.catalog_channel_id AND e.source_id=?
      LEFT JOIN epg_mappings m ON m.channel_id=c.id AND m.provider_id=c.provider_id
      WHERE c.provider_id=?
    ''',
                variables: [
                  Variable(serverEpgSourceId),
                  Variable(publicCatalogProviderId),
                ],
              )
              .get();
    final bindings = <db.EpgMappingsCompanion>[];
    final valid = <String>{};
    for (final row in rows) {
      final alreadyMapped = row.readNullable<String>('mapped_channel') != null;
      final ours =
          row.readNullable<String>('mapped_source') == serverEpgSourceId &&
          row.readNullable<String>('mapping_kind') == 'server' &&
          row.readNullable<int>('mapping_locked') == 0;
      if (alreadyMapped && !ours ||
          row.read<String>('name') != row.read<String>('catalog_name') ||
          row.readNullable<String>('tvg_id') !=
              row.readNullable<String>('catalog_epg_id') ||
          row.readNullable<String>('group_title') !=
              row.readNullable<String>('group_name')) {
        continue;
      }
      final metadata = jsonDecode(row.read<String>('metadata'));
      final id = row.read<String>('catalog_channel_id');
      final hash = row.read<String>('identity_hash');
      if (metadata is! Map ||
          metadata['id'] != id ||
          metadata['catalogIdentityHash'] != hash ||
          catalogEpgIdentityHash(metadata) != hash ||
          metadata['confidence'] is! num ||
          !(metadata['confidence'] as num).isFinite ||
          (metadata['confidence'] as num) < .95 ||
          (metadata['confidence'] as num) > 1) {
        continue;
      }
      final localId = row.read<String>('local_channel_id');
      final localEpgId = row.read<String>('local_epg_channel_id');
      valid.add(localId);
      final old = previous[localId];
      final confidence = (metadata['confidence'] as num).toDouble();
      if (old?.epgChannelId == localEpgId && old?.confidence == confidence) {
        continue;
      }
      bindings.add(
        db.EpgMappingsCompanion.insert(
          channelId: localId,
          providerId: publicCatalogProviderId,
          epgChannelId: localEpgId,
          epgSourceId: serverEpgSourceId,
          confidence: Value(confidence),
          source: const Value('server'),
        ),
      );
    }
    for (final mapping in owned) {
      if (!valid.contains(mapping.channelId)) {
        await database.deleteMapping(mapping.channelId, mapping.providerId);
      }
    }
    await database.upsertMappings(bindings);
    return valid.length;
  });
}
