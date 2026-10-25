import 'package:drift/drift.dart';

import '../datasources/local/database.dart' as db;
import '../models/server_epg_snapshot.dart';

/// All local providers and enabled XMLTV sources share one resolution policy.
class LocalEpgBinding {
  LocalEpgBinding(this.database);
  final db.AppDatabase database;
  static const kind = 'local_xmltv';

  static String idKey(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');
  static String nameKey(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(
        RegExp(r'(?:[\s\[(]+(?:hd|sd|fhd|1080p|720p)[\])]*|高清|标清|超清)$'),
        '',
      )
      .replaceAll(RegExp(r'[\s_-]+'), '');

  Future<int> reconcile({DateTime? at}) => database.transaction(() async {
    final now = (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final guide = await database
        .customSelect(
          '''
      SELECT e.id,e.channel_id,e.source_id,e.display_name,s.last_refresh,
        s.refresh_interval_hours,MAX(p.stop) AS coverage_end,
        MAX(CASE WHEN p.start<=? AND p.stop>? THEN 1 ELSE 0 END) AS has_current
      FROM epg_channels e JOIN epg_sources s ON s.id=e.source_id AND s.enabled=1
      JOIN epg_programmes p ON p.epg_channel_id=e.id AND p.stop>?
      WHERE e.source_id<>? GROUP BY e.id
    ''',
          variables: [
            Variable(now),
            Variable(now),
            Variable(now),
            Variable(serverEpgSourceId),
          ],
        )
        .get();
    final byExactId = <String, List<QueryRow>>{};
    final byId = <String, List<QueryRow>>{};
    final byName = <String, List<QueryRow>>{};
    for (final row in guide) {
      final raw = row.read<String>('channel_id');
      (byExactId[raw.trim()] ??= []).add(row);
      (byId[idKey(raw)] ??= []).add(row);
      final key = nameKey(row.read<String>('display_name'));
      if (key.isNotEmpty) (byName[key] ??= []).add(row);
    }
    final channels = await database.customSelect('''
      SELECT c.id,c.provider_id,c.name,c.tvg_id,c.tvg_name,c.group_title,
        r.name AS catalog_name,r.epg_id AS catalog_epg_id,r.group_name,
        x.country_code,x.region_code
      FROM channels c LEFT JOIN catalog_epg_routes r ON r.local_channel_id=c.id
      LEFT JOIN catalog_presentation_context x ON x.local_channel_id=c.id
    ''').get();
    final contexts = <String, Set<String>>{};
    for (final row in channels) {
      final country = row.readNullable<String>('country_code');
      if (country != null && country.isNotEmpty) {
        (contexts[nameKey(row.read<String>('name'))] ??= {}).add(
          '$country/${row.readNullable<String>('region_code') ?? ''}',
        );
      }
    }
    final allMappings = await database.select(database.epgMappings).get();
    String owner(String provider, String channel) => '$provider\u0000$channel';
    final old = {
      for (final m in allMappings) owner(m.providerId, m.channelId): m,
    };
    final valid = <String>{};
    final updates = <db.EpgMappingsCompanion>[];

    QueryRow? choose(
      List<QueryRow> candidates, {
      bool exactId = false,
      Set<String> names = const {},
    }) {
      if (candidates.isEmpty) return null;
      var eligible = candidates;
      if (exactId) {
        final aligned = candidates
            .where(
              (r) => names.contains(nameKey(r.read<String>('display_name'))),
            )
            .toList();
        if (aligned.isNotEmpty) {
          eligible = aligned;
        } else if (candidates.every(
          (r) => RegExp(r'^\d+$').hasMatch(r.read<String>('channel_id')),
        )) {
          return null;
        }
      }
      final perSource = <String, Set<String>>{};
      for (final row in eligible) {
        (perSource[row.read<String>('source_id')] ??= {}).add(
          row.read<String>('channel_id'),
        );
      }
      if (perSource.values.any((ids) => ids.length > 1)) return null;
      final identities = eligible
          .map(
            (r) =>
                '${idKey(r.read<String>('channel_id'))}|${nameKey(r.read<String>('display_name'))}',
          )
          .toSet();
      if (identities.length != 1) return null;
      int freshness(QueryRow row) {
        final refreshed = row.readNullable<int>('last_refresh');
        final hours = row.read<int>('refresh_interval_hours').clamp(1, 168);
        return refreshed != null && now - refreshed <= hours * 7200 ? 1 : 0;
      }

      eligible.sort((a, b) {
        var diff = freshness(b).compareTo(freshness(a));
        if (diff != 0) return diff;
        diff = b.read<int>('has_current').compareTo(a.read<int>('has_current'));
        if (diff != 0) return diff;
        diff = b
            .read<int>('coverage_end')
            .compareTo(a.read<int>('coverage_end'));
        if (diff != 0) return diff;
        return a
            .read<String>('source_id')
            .compareTo(b.read<String>('source_id'));
      });
      return eligible.first;
    }

    for (final row in channels) {
      final channel = row.read<String>('id');
      final provider = row.read<String>('provider_id');
      final key = owner(provider, channel);
      final previous = old[key];
      if (previous != null && (previous.locked || previous.source != kind)) {
        continue;
      }
      final names = {
        nameKey(row.read<String>('name')),
        if (row.readNullable<String>('tvg_name') != null)
          nameKey(row.read<String>('tvg_name')),
      };
      QueryRow? selected;
      final tvgId = row.readNullable<String>('tvg_id');
      if (tvgId != null && tvgId.trim().isNotEmpty) {
        final exact = byExactId[tvgId.trim()] ?? [];
        final candidates = exact.isNotEmpty ? exact : byId[idKey(tvgId)] ?? [];
        selected = choose(candidates, exactId: true, names: names);
        if (candidates.isNotEmpty && selected == null) continue;
      }
      if (selected == null) {
        final candidates = <QueryRow>{};
        for (final name in names) {
          final context = contexts[name] ?? <String>{};
          final countries = context
              .map((c) => c.split('/').first.toUpperCase())
              .toSet();
          final regions = context
              .where((c) => !c.endsWith('/'))
              .map((c) => c.toLowerCase())
              .toSet();
          if (countries.length > 1 || regions.length > 1) continue;
          candidates.addAll(byName[name] ?? []);
        }
        selected = choose(candidates.toList());
      }
      if (selected == null) continue;
      valid.add(key);
      final source = selected.read<String>('source_id');
      final epg = selected.read<String>('channel_id');
      if (previous?.epgSourceId == source && previous?.epgChannelId == epg) {
        continue;
      }
      updates.add(
        db.EpgMappingsCompanion.insert(
          channelId: channel,
          providerId: provider,
          epgChannelId: epg,
          epgSourceId: source,
          confidence: const Value(1),
          source: const Value(kind),
        ),
      );
    }
    for (final m in allMappings.where((m) => m.source == kind && !m.locked)) {
      if (!valid.contains(owner(m.providerId, m.channelId))) {
        await database.deleteMapping(m.channelId, m.providerId);
      }
    }
    await database.upsertMappings(updates);
    return valid.length;
  });
}
