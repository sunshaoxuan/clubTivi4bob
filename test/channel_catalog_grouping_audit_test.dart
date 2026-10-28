import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_name_normalizer.dart';
import 'package:clubtivi/data/services/channel_presentation_identity.dart';
import 'package:clubtivi/data/services/route_identity.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final copy = Platform.environment['BOBTV_CHANNEL_FIX_AUDIT_COPY'];
  test(
    'whole installed catalog replay with category and residual identity audit',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = db.AppDatabase.forTesting(NativeDatabase(File(copy!)));
      addTearDown(database.close);
      final all = await database.getAllChannels();
      final visible = all.where((c) => !c.hidden).toList();
      final keys = await database.channelPresentationKeys(visible);
      final catalogIds = await database.publicCatalogChannelIds(
        visible.map((c) => c.id),
      );
      final merges = await database.channelMergeIds(
        visible.map((c) => c.streamUrl),
      );
      String oldKey(db.Channel c) {
        final merge = merges[canonicalRouteUrl(c.streamUrl)];
        if (merge != null) return 'manual:$merge';
        if (c.providerId == 'bobtv-channel-catalog')
          return 'catalog:${catalogIds[c.id] ?? c.id}';
        final uhd = [
          c.name,
          c.tvgName ?? '',
          c.tvgId ?? '',
        ].any(ChannelNameNormalizer.isUltraHd);
        final oldName = ChannelNameNormalizer.normalize(
          c.name,
        ).replaceAll(RegExp(r'[^a-z0-9㐀-䶿一-鿿぀-ヿ가-힯]+', unicode: true), '');
        return '$oldName|${uhd ? 'uhd' : 'standard'}';
      }

      final names = <String, List<db.Channel>>{};
      for (final c in visible) {
        (names[ChannelNameNormalizer.normalize(c.name)] ??= []).add(c);
      }
      final changed = <Map<String, Object?>>[];
      final residual = <Map<String, Object?>>[];
      for (final entry in names.entries) {
        if (entry.key.isEmpty) continue;
        final before = entry.value.map(oldKey).toSet().length;
        final after = entry.value.map((c) => keys[c.id]).toSet().length;
        final row = <String, Object?>{
          'name': entry.value.first.name,
          'normalizedName': entry.key,
          'sourceRows': entry.value.length,
          'cardsBefore': before,
          'cardsAfter': after,
          'uniqueRoutes': entry.value
              .map((c) => canonicalRouteUrl(c.streamUrl))
              .toSet()
              .length,
          'groups': entry.value.map((c) => c.groupTitle).toSet().toList(),
          'guideIds': entry.value.map((c) => c.tvgId).toSet().toList(),
        };
        if (after < before) changed.add(row);
        if (after > 1) residual.add(row);
      }
      changed.sort(
        (a, b) => (b['cardsBefore'] as int).compareTo(a['cardsBefore'] as int),
      );
      residual.sort(
        (a, b) => (b['cardsAfter'] as int).compareTo(a['cardsAfter'] as int),
      );
      final examples = <Map<String, Object?>>[];
      for (final name in [
        '风云剧场',
        '风云足球',
        '风云音乐',
        '女性时尚',
        '兵器科技',
        '第一剧场',
        'CETV1',
        'CETV2',
        'CETV4',
      ]) {
        final rows = names[ChannelNameNormalizer.normalize(name)] ?? [];
        final digital = rows
            .where((c) => {'数字', '中国 / 数字'}.contains(c.groupTitle))
            .toList();
        if (digital.isEmpty) continue;
        final cards = digital.map((c) => keys[c.id]).toSet().length;
        expect(cards, 1, reason: '$name in digital category');
        examples.add({
          'name': name,
          'sourceRows': digital.length,
          'cardsAfter': cards,
          'uniqueRoutes': digital
              .map((c) => canonicalRouteUrl(c.streamUrl))
              .toSet()
              .length,
        });
      }
      final cards = ChannelPresentationIdentity.representatives(
        visible,
        idOf: (c) => c.id,
        keyOf: (c) => keys[c.id]!,
        scoreOf: (_) => 0,
      );
      final summary = <String, Object?>{
        'databaseCopyOnly': true,
        'sourceRows': all.length,
        'visibleSourceRows': visible.length,
        'cardsBefore': visible.map(oldKey).toSet().length,
        'cardsAfter': cards.length,
        'improvedNameGroups': changed.length,
        'residualSameNameGroups': residual.length,
        'screenshotExamples': examples,
      };
      final output = Platform.environment['BOBTV_CHANNEL_FIX_REPORT'];
      if (output != null) {
        await File(output).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'summary': summary,
            'improvedGroups': changed,
            'residualGroups': residual,
          }),
        );
      }
      // Counts and channel names only. Never print stream URLs or credentials.
      // ignore: avoid_print
      print(jsonEncode(summary));
      expect(await database.getAllChannels(), hasLength(all.length));
      expect(keys.length, greaterThanOrEqualTo(visible.length));
      expect(changed.length, greaterThan(1));
    },
    skip: copy == null
        ? 'Set BOBTV_CHANNEL_FIX_AUDIT_COPY to a SQLite backup'
        : false,
  );
}
