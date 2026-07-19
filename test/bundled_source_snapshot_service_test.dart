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
