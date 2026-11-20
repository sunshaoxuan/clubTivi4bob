import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../datasources/local/database.dart' as db;
import '../models/server_epg_snapshot.dart';
import 'epg_ui_refresh.dart';

/// Resolves only exactly bound public catalogue routes. Private sources never
/// become automatic external subtitle requests through a name match.
class ServerEpgProgrammeLookup {
  ServerEpgProgrammeLookup(
    this.database, {
    DateTime Function()? now,
    Future<int> Function(String)? timeshift,
  }) : _now = now ?? DateTime.now,
       _timeshift = timeshift ?? _savedTimeshift;
  final db.AppDatabase database;
  final DateTime Function() _now;
  final Future<int> Function(String) _timeshift;

  static Future<int> _savedTimeshift(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('epg_timeshifts');
    if (raw == null) return 0;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return 0;
    }
    final shift = decoded is Map ? decoded[id] : null;
    return shift is int && shift.abs() <= 24 ? shift : 0;
  }

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
    if (rows.isEmpty) return _mappedProgramme(source, at);
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

  // The guide already selects these persisted mappings, including manual
  // ones. Deliberately exclude name-only fallback and private route URLs.
  Future<Map<String, Object?>?> _mappedProgramme(String source, int at) async {
    final bindings = await database
        .customSelect(
          '''
      SELECT c.id AS local_id,c.provider_id,r.catalog_channel_id AS catalog_id,
        m.epg_source_id
      FROM channels c JOIN catalog_epg_routes r ON r.local_channel_id=c.id
      JOIN epg_mappings m ON m.channel_id=c.id AND m.provider_id=c.provider_id
      JOIN epg_sources e ON e.id=m.epg_source_id AND e.enabled=1
      WHERE c.stream_url=? AND m.epg_source_id<>? LIMIT 2
      ''',
          variables: [Variable(source), Variable(serverEpgSourceId)],
        )
        .get();
    if (bindings.length != 1) return null;
    final binding = bindings.single;
    final localId = binding.read<String>('local_id');
    final shift = await _timeshift(localId) * 3600;
    final sourceId = binding.read<String>('epg_source_id');
    final epgId = await resolveLiveEpgId(
      database,
      channelId: localId,
      providerId: binding.read<String>('provider_id'),
      actualStreamUrl: source,
    );
    if (epgId == null) return null;
    final programmes = await database
        .customSelect(
          '''
      SELECT title,start,stop FROM epg_programmes
      WHERE epg_channel_id=? AND source_id=? AND start<=? AND stop>?
      ORDER BY start DESC LIMIT 2
      ''',
          variables: [
            Variable(epgId),
            Variable(sourceId),
            Variable(at - shift),
            Variable(at - shift),
          ],
        )
        .get();
    if (programmes.length != 1) return null;
    final row = programmes.single;
    final channel = binding.read<String>('catalog_id');
    final title = row.read<String>('title').trim();
    if (title.isEmpty || title.runes.length > 200) return null;
    final start = row.read<int>('start') + shift;
    final stop = row.read<int>('stop') + shift;
    final digest = sha256.convert(
      utf8.encode(jsonEncode([channel, title, start, stop])),
    );
    return {
      'key': 'player-epg:$digest',
      'catalogChannelId': channel,
      'title': title,
      'startUtc': start,
      'stopUtc': stop,
      'contextKind': 'player-epg-v1',
    };
  }
}
