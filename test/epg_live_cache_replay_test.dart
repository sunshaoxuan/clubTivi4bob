import 'dart:convert';
import 'dart:io';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/datasources/parsers/xmltv_parser.dart';
import 'package:clubtivi/data/services/epg_refresh_service.dart';
import 'package:clubtivi/data/services/epg_ui_refresh.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['BOBTV_EPG_REPLAY_DB'];
  final fixtures = Platform.environment['BOBTV_EPG_FIXTURES'];
  test(
    'real XMLTV refresh and public route lookup on a disposable cache copy',
    skip: path == null || fixtures == null,
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase(File(path!)));
      addTearDown(database.close);
      final output = <String, Object?>{};
      for (final (name, id) in [
        ('china', 'hotel-cn-epg'),
        ('extended', 'hotel-cn-epg-extended'),
      ]) {
        final result = XmltvParser().parseBytes(
          File('$fixtures/$name.xml.bin').readAsBytesSync(),
          sourceId: id,
        );
        await EpgRefreshService(database).importParsed(id, result);
        output[id] = {
          'accepted': result.programmes.length,
          'skipped': result.rejectedProgrammes,
        };
      }
      final mappings = await database
          .customSelect(
            "SELECT source,count(*) AS n FROM epg_mappings GROUP BY source",
          )
          .get();
      output['mappings'] = [for (final r in mappings) r.data];
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final current = await database.customSelect('''
        SELECT m.channel_id FROM epg_mappings m JOIN epg_programmes p
        ON p.epg_channel_id=CASE WHEN m.epg_channel_id LIKE m.epg_source_id || '_%'
          THEN m.epg_channel_id ELSE m.epg_source_id || '_' || m.epg_channel_id END
        WHERE p.start <= $now AND p.stop > $now GROUP BY m.channel_id
      ''').get();
      output['currentProgrammeRoutes'] = current.length;
      expect(current.length, greaterThan(2));
      final example = current.first.read<String>('channel_id');
      expect(await resolveLiveEpgId(database, channelId: example), isNotNull);
      output['integrity'] =
          (await database.customSelect('PRAGMA integrity_check').getSingle())
              .data;
      print(jsonEncode(output));
    },
  );
}
