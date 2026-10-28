import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/services/channel_presentation_identity.dart';
import 'package:clubtivi/data/services/channel_name_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final path = Platform.environment['BOBTV_DUPLICATE_AUDIT_DB'];
  final candidatePath = Platform.environment['BOBTV_DUPLICATE_AUDIT_CATALOG'];
  test(
    'read-only installed database presentation audit, no app control',
    () async {
      final result = await Process.run('sqlite3', [
        '-readonly',
        '-json',
        path!,
        '''
      SELECT c.id,c.name,c.provider_id,c.stream_url,c.group_title,c.tvg_id,c.tvg_name,
        r.catalog_channel_id,m.merge_id,
        EXISTS(SELECT 1 FROM favorite_list_channels f WHERE f.channel_id=c.id) favored
      FROM channels c LEFT JOIN catalog_epg_routes r ON r.local_channel_id=c.id
      LEFT JOIN channel_merge_overrides m ON m.url=c.stream_url
    ''',
      ]);
      expect(result.exitCode, 0);
      final rows = (jsonDecode(result.stdout as String) as List).cast<Map>();
      final routes = [
        for (final r in rows)
          ChannelPresentationRoute(
            id: r['id'] as String,
            name: r['name'] as String,
            url: r['stream_url'] as String,
            group: r['group_title'] as String?,
            tvgName: r['tvg_name'] as String?,
            tvgId: r['tvg_id'] as String?,
            mergeId: r['merge_id'] as String?,
            catalogId: r['provider_id'] == 'bobtv-channel-catalog'
                ? (r['catalog_channel_id'] ?? r['id']) as String
                : null,
          ),
      ];
      final keys = ChannelPresentationIdentity.keys(routes);
      final favorites = rows.where((r) => r['favored'] == 1).toList();
      String oldKey(Map r) => r['merge_id'] != null
          ? 'manual:${r['merge_id']}'
          : r['provider_id'] == 'bobtv-channel-catalog'
          ? 'catalog:${r['catalog_channel_id'] ?? r['id']}'
          : '${ChannelNameNormalizer.normalize(r['name'] as String)}|'
                '${[r['name'], r['tvg_id'] ?? '', r['tvg_name'] ?? ''].any((v) => ChannelNameNormalizer.isUltraHd(v as String)) ? 'uhd' : 'standard'}';
      final before = favorites.map(oldKey).toSet().length;
      final after = favorites.map((r) => keys[r['id']]!).toSet().length;
      int? candidateCards;
      if (candidatePath != null) {
        final catalog =
            jsonDecode(
                  utf8.decode(
                    gzip.decode(File(candidatePath).readAsBytesSync()),
                  ),
                )
                as Map;
        final ids = <String, String>{
          for (final c in catalog['channels'] as List)
            for (final r in c['routes'] as List)
              'bobtv-channel-catalog:${r['id']}': c['id'] as String,
        };
        final candidateKeys = ChannelPresentationIdentity.keys([
          for (final route in routes)
            ChannelPresentationRoute(
              id: route.id,
              name: route.name,
              url: route.url,
              group: route.group,
              tvgName: route.tvgName,
              tvgId: route.tvgId,
              catalogId: ids[route.id] ?? route.catalogId,
              mergeId: route.mergeId,
            ),
        ]);
        candidateCards = favorites
            .map((r) => candidateKeys[r['id']])
            .toSet()
            .length;
        expect(candidateCards, lessThanOrEqualTo(after));
      }
      expect(after, lessThanOrEqualTo(before));
      // Printed evidence contains counts only, never private routes or credentials.
      // ignore: avoid_print
      print(
        jsonEncode({
          'readOnly': true,
          'sourceRows': rows.length,
          'favoriteCardsBefore': before,
          'favoriteCardsAfterClientFix': after,
          'favoriteCardsAfterClientAndCatalogFix': candidateCards,
          'favoritesMembershipRowsPreserved': favorites.length,
          'rowsDeleted': 0,
          'appRestarted': false,
        }),
      );
    },
    skip: path == null
        ? 'Set BOBTV_DUPLICATE_AUDIT_DB for a read-only local audit'
        : false,
  );
}
