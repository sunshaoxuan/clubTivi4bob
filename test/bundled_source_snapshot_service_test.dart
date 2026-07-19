import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/bundled_source_snapshot_service.dart';
import 'package:clubtivi/data/services/github_ai_crawler_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled snapshot contains unique CCTV5 4K discovery routes', () {
    const expectedUrls = <String>{
      'http://[2409:8087:2001:20:2800:0:df6e:eb22]/ott.mobaibox.com/PLTV/4/224/3221228502/index.m3u8',
      'http://ott.mobaibox.com/PLTV/4/224/3221228502/index.m3u8',
      'http://148.135.93.213:81/live.php?id=CCTV5-4K',
      'http://119.98.177.131:4000/rtp/239.69.1.12:9712',
      'http://171.80.228.240:4000/rtp/239.69.1.12:9712',
      'http://27.19.213.7:4022/rtp/239.69.1.12:9712',
      'http://27.25.77.223:4000/rtp/239.69.1.12:9712',
      'http://59.173.122.26:10001/rtp/239.69.1.12:9712',
      'http://59.173.123.163:19999/rtp/239.69.1.12:9712',
      'http://cqshushu.us.kg:2086/公众号【医工学习日志】/jiangsu.php?id=cctv5avs',
    };
    final decoded =
        jsonDecode(
              utf8.decode(
                gzip.decode(
                  File(
                    BundledSourceSnapshotService.assetPath,
                  ).readAsBytesSync(),
                ),
              ),
            )
            as Map<String, dynamic>;
    final channels = (decoded['channels'] as List).cast<Map>();
    final found = channels
        .where((channel) => expectedUrls.contains(channel['streamUrl']))
        .toList();

    expect(found, hasLength(expectedUrls.length));
    expect(found.map((channel) => channel['streamUrl']).toSet(), expectedUrls);
    expect(found.map((channel) => channel['name']).toSet(), {'CCTV5 4K'});
    expect(found.map((channel) => channel['tvgId']).toSet(), {'CCTV5'});
    expect(found.map((channel) => channel['groupTitle']).toSet(), {'央视频道'});
    expect(found.map((channel) => channel['confidence']).toSet(), {0.25});
  });

  test('bundled source snapshot imports once with public provenance', () async {
    SharedPreferences.setMockInitialValues({});
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final payload = <String, dynamic>{
      'schemaVersion': 1,
      'snapshotId': 'test-snapshot',
      'generatedAt': '2026-07-19T05:20:58Z',
      'channels': [
        {
          'id': 'github-ai-test-route',
          'name': 'CCTV5',
          'streamUrl': 'https://example.com/cctv5/live.m3u8',
          'tvgId': 'CCTV5',
          'tvgName': 'CCTV5',
          'tvgLogo': null,
          'groupTitle': '体育',
          'channelNumber': 5,
          'githubOwner': 'sample',
          'githubRepo': 'iptv',
          'githubRef': 'commit-1',
          'githubPath': 'odd/location/data.bin',
          'sourceDocumentUrl':
              'https://github.com/sample/iptv/blob/main/odd/location/data.bin',
          'confidence': 0.91,
        },
      ],
    };
    final bytes = Uint8List.fromList(
      gzip.encode(utf8.encode(jsonEncode(payload))),
    );
    final service = BundledSourceSnapshotService(
      database: database,
      loadBytes: () async => bytes,
    );

    expect(await service.run(), 1);
    expect(await service.run(), 0);

    final channels = await database.getChannelsForProvider(
      GitHubAiCrawlerService.providerId,
    );
    final provenance = await database.getDiscoveredStreamSources();
    expect(channels, hasLength(1));
    expect(channels.single.name, 'CCTV5');
    expect(channels.single.favorite, isFalse);
    expect(provenance, hasLength(1));
    expect(provenance.single.githubOwner, 'sample');
    expect(provenance.single.githubPath, 'odd/location/data.bin');

    await database.close();
  });
}
