import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/epg_refresh_service.dart';
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

void main() {
  test('Xtream uses its own authenticated guide for exact source IDs', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final guide = EpgRefreshService(database);
    Future<void>? pending;
    final manager = ProviderManager(
      database,
      refreshEpgSource: (id) {
        return pending = guide.refreshSource(id);
      },
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await guide.shutdown();
      await server.close(force: true);
      await database.close();
    });
    final origin = 'http://127.0.0.1:${server.port}';
    final now = DateTime.now().toUtc();
    String at(int minutes) =>
        '${DateFormat("yyyyMMddHHmmss").format(now.add(Duration(minutes: minutes)))} +0000';
    final requests = <Uri>[];
    var guideAvailable = true;
    server.listen((request) async {
      requests.add(request.uri);
      switch (request.uri.path) {
        case '/account/player_api.php':
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode([
              {
                'stream_id': 1,
                'name': 'Shared name',
                'epg_channel_id': 27,
                'stream_icon': '$origin/logo.png',
              },
              {
                'stream_id': 2,
                'name': 'Shared name',
                'epg_channel_id': 'other',
                'stream_icon': '$origin/logo.png',
              },
            ]),
          );
          break;
        case '/account/xmltv.php' when guideAvailable:
          request.response.write('''<tv>
<channel id="27"><display-name>Shared name</display-name></channel>
<programme channel="27" start="${at(-5)}" stop="${at(10)}"><title>Current title</title></programme>
<programme channel="27" start="${at(10)}" stop="${at(30)}"><title>Next title</title></programme>
</tv>''');
          break;
        default:
          request.response.statusCode = 404;
      }
      await request.response.close();
    });
    const password = 'a&b /+';
    await manager.addXtreamProvider(
      id: 'account-source',
      name: 'Xtream source',
      url: '$origin/account/',
      username: 'viewer',
      password: password,
    );
    await pending;
    expect(requests.map((uri) => uri.path), [
      '/account/player_api.php',
      '/account/xmltv.php',
    ]);
    for (final uri in requests) {
      expect(uri.queryParameters['username'], 'viewer');
      expect(uri.queryParameters['password'], password);
    }
    final source = (await database.getAllEpgSources()).single;
    expect(source.url, '$origin/account/xmltv.php');
    expect(
      (await database.getAllMappings()).single.channelId,
      'account-source_1',
    );
    expect(
      (await database.select(database.epgProgrammes).get()).map(
        (row) => row.title,
      ),
      ['Current title', 'Next title'],
    );
    guideAvailable = false;
    await expectLater(guide.refreshSource(source.id), throwsStateError);
    expect((await database.select(database.epgProgrammes).get()).length, 2);
    await manager.deleteProvider('account-source');
    expect(await database.getAllMappings(), isEmpty);
    expect(await database.getAllEpgSources(), isEmpty);
    expect(await database.getChannelsForProvider('account-source'), isEmpty);
  });

  test(
    'playlist guides are fetched directly and scoped by provider and tvg-id',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final guide = EpgRefreshService(database);
      final pending = <Future<void>>[];
      final manager = ProviderManager(
        database,
        refreshEpgSource: (id) {
          final refresh = guide.refreshSource(id);
          pending.add(refresh);
          return refresh;
        },
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await guide.shutdown();
        await server.close(force: true);
        await database.close();
      });
      final origin = 'http://127.0.0.1:${server.port}';
      final now = DateTime.now().toUtc();
      String xmlTime(int minutes) =>
          '${DateFormat("yyyyMMddHHmmss").format(now.add(Duration(minutes: minutes)))} +0000';
      var declaresGuide = true;
      final guideVisits = <String>[];
      server.listen((request) async {
        final path = request.uri.path;
        final first = path.startsWith('/first/');
        if (path.endsWith('playlist.m3u')) {
          final filename = first ? 'guide.xml' : 'guide.xml.gz';
          final declared = first && !declaresGuide
              ? ''
              : ' x-tvg-url="$filename" url-tvg="./$filename"';
          request.response.write('''#EXTM3U$declared
#EXTINF:-1 tvg-id="7" tvg-logo="$origin/logo.png",Shared station label
$origin/live/${first ? 'one' : 'two'}
#EXTINF:-1 tvg-id="missing" tvg-logo="$origin/logo.png",Other station
$origin/live/other
''');
        } else if (path.endsWith('guide.xml') ||
            path.endsWith('guide.xml.gz')) {
          guideVisits.add(path);
          expect(request.uri.hasQuery, false);
          final title = first
              ? 'First provider programme'
              : 'Second provider programme';
          final xml =
              '''<tv>
<channel id="7"><display-name>Provider guide label</display-name></channel>
<programme channel="7" start="${xmlTime(-5)}" stop="${xmlTime(10)}"><title>$title</title></programme>
<programme channel="7" start="${xmlTime(10)}" stop="${xmlTime(30)}"><title>Next programme</title></programme>
</tv>''';
          if (first) {
            request.response.write(xml);
          } else {
            request.response.add(gzip.encode(utf8.encode(xml)));
          }
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      for (final provider in ['first', 'second']) {
        await manager.addM3uProvider(
          id: provider,
          name: provider,
          url: '$origin/$provider/playlist.m3u?private=fixture',
        );
        await Future.wait(pending);
      }
      expect(guideVisits, ['/first/guide.xml', '/second/guide.xml.gz']);
      final mappings = await database.getAllMappings();
      expect(mappings.length, 2);
      final upcoming = await database.select(database.epgProgrammes).get();
      for (final mapping in mappings) {
        expect(mapping.epgChannelId, '7');
        final titles = upcoming
            .where((row) => row.sourceId == mapping.epgSourceId)
            .map((row) => row.title);
        expect(
          titles,
          contains(
            mapping.providerId == 'first'
                ? 'First provider programme'
                : 'Second provider programme',
          ),
        );
      }
      declaresGuide = false;
      await manager.refreshProvider('first');
      expect((await database.getAllMappings()).single.providerId, 'second');
      expect((await database.getChannelsForProvider('first')).length, 2);
      await manager.deleteProvider('second');
      expect(await database.getAllEpgSources(), isEmpty);
      expect(await database.getAllMappings(), isEmpty);
    },
  );
}
