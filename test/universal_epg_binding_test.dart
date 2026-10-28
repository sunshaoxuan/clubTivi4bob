import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/datasources/parsers/xmltv_parser.dart';
import 'package:clubtivi/data/services/epg_refresh_service.dart';
import 'package:clubtivi/data/services/local_epg_binding.dart';
import 'package:clubtivi/data/services/epg_ui_refresh.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'public and private channels use all configured guides, independent of country and genre',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      for (final provider in ['bobtv-channel-catalog', 'private-playlist']) {
        await database.upsertProvider(
          db.ProvidersCompanion.insert(
            id: provider,
            name: provider,
            type: 'm3u',
          ),
        );
      }
      await database.upsertEpgSource(
        db.EpgSourcesCompanion.insert(
          id: 'custom-world-guide',
          name: 'World guide',
          url: 'https://example.org/world.xml',
        ),
      );
      final fixtures = [
        ('uk', 'BBC One', 'BBCOne.uk', 'GB', 'bobtv-channel-catalog'),
        ('hk', '翡翠台', 'TVBJade.hk', 'HK', 'bobtv-channel-catalog'),
        ('jp', 'NHK World', 'NHKWorld.jp', 'JP', 'bobtv-channel-catalog'),
        ('us', 'Local News', 'LocalNews.us', 'US', 'bobtv-channel-catalog'),
        ('shift', 'BBC One +1', 'BBCOne+1.uk', 'GB', 'bobtv-channel-catalog'),
        ('loop', 'Cinema 24/7', 'cinema247', 'US', 'bobtv-channel-catalog'),
        ('private', 'Das Erste HD', '', 'DE', 'private-playlist'),
        ('manual', 'Manual choice', 'NHKWorld.jp', 'JP', 'private-playlist'),
        ('locked', 'Locked choice', 'BBCOne.uk', 'GB', 'bobtv-channel-catalog'),
        ('ambiguous', 'News', '', 'GB', 'bobtv-channel-catalog'),
      ];
      for (final (id, name, epg, country, provider) in fixtures) {
        await database.upsertChannels([
          db.ChannelsCompanion.insert(
            id: id,
            providerId: provider,
            name: name,
            streamUrl: 'https://example.org/$id',
            tvgId: epg.isEmpty ? const Value.absent() : Value(epg),
          ),
        ]);
        if (provider == 'bobtv-channel-catalog') {
          await database.customStatement(
            'INSERT INTO catalog_epg_routes VALUES(?,?,?,?,?,?)',
            [id, id, 'hash', name, epg.isEmpty ? null : epg, null],
          );
          await database.customStatement(
            'INSERT INTO catalog_presentation_context VALUES(?,?,?)',
            [id, country, null],
          );
        }
      }
      for (final (id, provider) in [
        ('manual', 'private-playlist'),
        ('locked', 'bobtv-channel-catalog'),
      ]) {
        await database.upsertMapping(
          db.EpgMappingsCompanion.insert(
            channelId: id,
            providerId: provider,
            epgChannelId: 'chosen',
            epgSourceId: 'custom-world-guide',
            source: const Value('manual'),
            locked: const Value(true),
          ),
        );
      }
      final entries = [
        ('BBCOne.uk', 'BBC One'),
        ('TVBJade.hk', '翡翠台'),
        ('NHKWorld.jp', 'NHK World'),
        ('LocalNews.us', 'Local News'),
        ('BBCOne+1.uk', 'BBC One +1'),
        ('cinema247', 'Cinema 24/7'),
        ('ard.de', 'Das Erste'),
        ('news.us', 'News'),
        ('news.gb', 'News'),
      ];
      final xml =
          '<tv>${entries.map((e) => '<channel id="${e.$1}"><display-name>${e.$2}</display-name></channel>').join()}${entries.map((e) => '<programme channel="${e.$1}" start="20300101000000 +0000" stop="20300101020000 +0000"><title>Programme ${e.$1}</title></programme>').join()}</tv>';
      await EpgRefreshService(database).importParsed(
        'custom-world-guide',
        XmltvParser().parse(xml, sourceId: 'custom-world-guide'),
        at: DateTime.utc(2030, 1, 1, 1),
      );
      final mappings = await database.select(database.epgMappings).get();
      for (final id in ['uk', 'hk', 'jp', 'us', 'shift', 'loop', 'private']) {
        expect(mappings.any((m) => m.channelId == id), true, reason: id);
        final key = await resolveLiveEpgId(database, channelId: id);
        expect(key, isNotNull, reason: id);
        final programmes = await database.getUpcomingProgrammes(
          epgChannelId: key!,
          at: DateTime.utc(2030, 1, 1, 1),
        );
        expect(programmes.single.title, startsWith('Programme'), reason: id);
      }
      expect(mappings.any((m) => m.channelId == 'ambiguous'), false);
      for (final id in ['manual', 'locked']) {
        expect(
          mappings.singleWhere((m) => m.channelId == id).epgChannelId,
          'chosen',
        );
      }
      await database.customStatement(
        "UPDATE epg_sources SET enabled=0 WHERE id='custom-world-guide'",
      );
      await LocalEpgBinding(
        database,
      ).reconcile(at: DateTime.utc(2030, 1, 1, 1));
      expect(
        (await database.select(database.epgMappings).get())
            .map((m) => m.channelId)
            .toSet(),
        {'manual', 'locked'},
      );
    },
  );
}
