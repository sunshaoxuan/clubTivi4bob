import 'dart:convert';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/stream_health_tracker.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('failed routes move behind untried routes before candidate limits', () {
    const urls = ['failed-1', 'failed-2', 'new-1', 'new-2'];
    final scores = {'failed-1': 0.2, 'failed-2': 0.3};
    expect(
      PlayerService.prioritizeCandidateUrls(
        urls,
        (url) => scores[url] ?? 0.5,
      ).take(2),
      ['new-1', 'new-2'],
    );
    expect(
      PlayerService.prioritizeCandidateUrls(
        urls,
        (url) => scores[url] ?? 0.5,
        preferredUrl: 'failed-2',
      ).first,
      'failed-2',
    );
  });

  test('legacy saved failures remain effective after tracker reload', () async {
    const url = 'https://example.com/cctv5.m3u8';
    SharedPreferences.setMockInitialValues({
      'stream_health_scores': jsonEncode({
        'legacy-process-hash': {
          'url': url,
          'stalls': 0,
          'bufSum': 0,
          'bufN': 0,
          'ttff': 0,
          'ok': 0,
          'fail': 5,
          'bps': 0,
          'windows': {},
          'ts': DateTime.now().millisecondsSinceEpoch,
        },
      }),
    });
    final tracker = StreamHealthTracker();
    await tracker.load();
    expect(tracker.getScore(url), lessThan(tracker.getScore('new-route')));
  });

  test('manual retirement blocks one address across providers', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    const rejected = 'https://example.com/ad.m3u8';
    const healthy = 'https://example.com/tv.m3u8';
    try {
      await database.upsertProvider(
        db.ProvidersCompanion.insert(id: 'a', name: 'A', type: 'm3u'),
      );
      await database.upsertProvider(
        db.ProvidersCompanion.insert(id: 'b', name: 'B', type: 'm3u'),
      );
      await database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'a-ad', providerId: 'a', name: 'CCTV5', streamUrl: rejected,
        ),
        db.ChannelsCompanion.insert(
          id: 'b-ad', providerId: 'b', name: 'CCTV5', streamUrl: rejected,
        ),
        db.ChannelsCompanion.insert(
          id: 'b-tv', providerId: 'b', name: 'CCTV5', streamUrl: healthy,
        ),
      ]);
      expect(await database.blockAndDeleteStreamUrl(
        rejected,
        reason: 'user_reported_wrong_content',
      ), 2);
      await database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'a-ad', providerId: 'a', name: 'CCTV5', streamUrl: rejected,
        ),
      ]);
      final remaining = await database.getAllChannels();
      expect(remaining.map((channel) => channel.streamUrl), [healthy]);
    } finally {
      await database.close();
    }
  });
}
