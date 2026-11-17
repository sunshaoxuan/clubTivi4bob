import 'dart:convert';
import 'package:drift/drift.dart';
import '../datasources/local/database.dart' as db;
import '../models/server_epg_snapshot.dart';

/// Resolves only exactly bound public catalogue routes. Private sources never
/// become automatic external subtitle requests through a name match.
class ServerEpgProgrammeLookup {
  ServerEpgProgrammeLookup(this.database, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final db.AppDatabase database;
  final DateTime Function() _now;

  Future<Map<String, Object?>?> forSource(String source) async {
    final uri = Uri.tryParse(source);
    if (uri == null || uri.userInfo.isNotEmpty) return null;
    final at = _now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final rows = await database
        .customSelect(
          '''
      SELECT p.metadata AS programme,s.metadata AS identity,
        r.identity_hash AS current_hash,r.catalog_channel_id AS catalog_id,c.id AS local_id
      FROM channels c JOIN catalog_epg_routes r ON r.local_channel_id=c.id
      JOIN epg_mappings m ON m.channel_id=c.id AND m.epg_source_id=?
      JOIN epg_sources e ON e.id=m.epg_source_id AND e.enabled=1
      JOIN server_epg_programme_identities p ON p.channel_id=m.epg_channel_id
      JOIN server_epg_identities s ON m.epg_channel_id=? || '_' || s.channel_id
      WHERE c.stream_url=? AND p.start_utc<=? AND p.stop_utc>? LIMIT 2
    ''',
          variables: [
            Variable(serverEpgSourceId),
            Variable(serverEpgSourceId),
            Variable(source),
            Variable(at),
            Variable(at),
          ],
        )
        .get();
    if (rows.length != 1) return null;
    final row = rows.single;
    final identity = jsonDecode(row.read<String>('identity')) as Map;
    if (!serverEpgMatchesRoute(
      identity,
      row.read<String>('catalog_id'),
      row.read<String>('current_hash'),
      row.read<String>('local_id'),
      source,
    )) {
      return null;
    }
    final programme = Map<String, Object?>.from(
      jsonDecode(row.read<String>('programme')) as Map,
    );
    if (programme['catalogChannelId'] != identity['id']) {
      return null;
    }
    return Map.unmodifiable(programme);
  }
}
