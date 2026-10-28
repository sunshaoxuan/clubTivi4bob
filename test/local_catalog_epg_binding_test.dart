import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/datasources/parsers/xmltv_parser.dart';
import 'package:clubtivi/data/services/epg_refresh_service.dart';
import 'package:clubtivi/data/services/local_catalog_epg_binding.dart';
import 'package:clubtivi/data/services/epg_ui_refresh.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'bad XMLTV rows cannot reject valid programmes; exact public fallback is shared',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.upsertProvider(
        db.ProvidersCompanion.insert(
          id: 'bobtv-channel-catalog',
          name: 'public',
          type: 'm3u',
        ),
      );
      await database.upsertEpgSource(
        db.EpgSourcesCompanion.insert(
          id: 'hotel-cn-epg',
          name: 'CN',
          url: 'https://example.org/guide',
        ),
      );
      for (final (id, name, country) in [
        ('china', 'CCTV5+', 'CN'),
        ('different', 'CCTV5', 'CN'),
        ('foreign', 'CCTV5+', 'US'),
        ('delay', 'CCTV5+1', 'CN'),
        ('manual', 'CCTV5+', 'CN'),
        ('server', 'CCTV5+', 'CN'),
      ]) {
        await database.upsertChannels([
          db.ChannelsCompanion.insert(
            id: id,
            providerId: 'bobtv-channel-catalog',
            name: name,
            tvgId: id == 'china' ? const Value('exact') : const Value.absent(),
            streamUrl: 'https://example.org/$id',
          ),
        ]);
        await database.customStatement(
          'INSERT INTO catalog_epg_routes VALUES(?,?,?,?,?,?)',
          [id, id, 'hash', name, id == 'china' ? 'exact' : null, null],
        );
        await database.customStatement(
          'INSERT INTO catalog_presentation_context VALUES(?,?,?)',
          [id, country, null],
        );
      }
      for (final id in ['manual', 'server']) {
        await database.upsertMapping(
          db.EpgMappingsCompanion.insert(
            channelId: id,
            providerId: 'bobtv-channel-catalog',
            epgSourceId: 'hotel-cn-epg',
            epgChannelId: id == 'server' ? 'hotel-cn-epg_exact' : 'exact',
            source: Value(id),
            locked: Value(id == 'manual'),
          ),
        );
      }
      final parsed = XmltvParser().parse('''<tv>
      <channel id="exact"><display-name>CCTV5+</display-name></channel>
      <programme channel="exact" start="20300101000000 +0000" stop="20300101010000 +0000"><title>Valid</title></programme>
      <programme channel="exact" start="20300101235900 +0000" stop="20300101000100 +0000"><title>Broken midnight</title></programme>
      <programme channel="exact" start="20300101000000 +0000" stop="20300101000000 +0000"><title>Zero</title></programme>
      <programme channel="unknown" start="20300101000000 +0000" stop="20300101010000 +0000"><title>Orphan</title></programme>
    </tv>''', sourceId: 'hotel-cn-epg');
      expect(parsed.programmes.length, 1);
      await EpgRefreshService(
        database,
      ).importParsed('hotel-cn-epg', parsed, at: DateTime.utc(2030, 1, 1));
      var mappings = await database.select(database.epgMappings).get();
      expect(mappings.map((m) => m.channelId).toSet(), {
        'china',
        'manual',
        'server',
      });
      expect(
        mappings.singleWhere((m) => m.channelId == 'china').source,
        LocalCatalogEpgBinding.kind,
      );
      expect(
        await resolveLiveEpgId(database, channelId: 'china'),
        'hotel-cn-epg_exact',
      );
      expect(
        await resolveLiveEpgId(database, channelId: 'server'),
        'hotel-cn-epg_exact',
      );
      await LocalCatalogEpgBinding(
        database,
      ).reconcile(at: DateTime.utc(2030, 1, 2));
      mappings = await database.select(database.epgMappings).get();
      expect(mappings.map((m) => m.channelId).toSet(), {'manual', 'server'});
    },
  );
}
