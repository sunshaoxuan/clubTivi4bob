import 'dart:convert';
import 'dart:async';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/stream_health_tracker.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup uses highest network score beyond route 24 without media probes', () async {
    final urls = List.generate(60, (index) => 'https://example.com/route-$index.m3u8');
    var prepared = 0;
    final scored = <String>[];
    final selected = await PlayerService.selectInitialRoute(urls,
      prepare: (_) async { prepared++; },
      score: (url) { scored.add(url); return url == urls.last ? .99 : .5; },
      isCurrent: () => true, allowed: (_) => true);
    expect(selected, urls.last);
    expect(prepared, 1);
    expect(scored, hasLength(60));
  });

  test('failed route is excluded and next highest route is selected', () async {
    const urls = ['https://example.com/low', 'https://example.com/best', 'https://example.com/next'];
    final scores = {urls[0]: .2, urls[1]: .9, urls[2]: .8};
    final failed = <String>{};
    Future<String?> choose() => PlayerService.selectInitialRoute(urls,
      prepare: (_) async {}, score: (url) => scores[url]!,
      isCurrent: () => true, allowed: (url) => !failed.contains(url));
    expect(await choose(), urls[1]);
    failed.add(urls[1]);
    expect(await choose(), urls[2]);
  });

  test('offline scoring keeps current-network cached best candidate', () async {
    expect(await PlayerService.selectInitialRoute(
      ['https://example.com/low', 'https://example.com/best'],
      prepare: (_) async => throw StateError('503'),
      score: (url) => url.endsWith('best') ? .9 : .2,
      isCurrent: () => true, allowed: (_) => true),
      'https://example.com/best');
  });

  test('late ranking cannot select a superseded channel or retired route', () async {
    final pending = Completer<void>();
    var current = true;
    var allowed = true;
    final first = PlayerService.selectInitialRoute(['https://example.com/live'],
      prepare: (_) => pending.future, score: (_) => .9,
      isCurrent: () => current, allowed: (_) => allowed);
    current = false;
    pending.complete();
    expect(await first, isNull);
    current = true;
    allowed = false;
    expect(await PlayerService.selectInitialRoute(['https://example.com/live'],
      prepare: (_) async {}, score: (_) => .9,
      isCurrent: () => current, allowed: (_) => allowed), isNull);
  });

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

  test('decoded playback raises weight and a manual skip lowers it once',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tracker = StreamHealthTracker();
    await tracker.load();
    const url = 'https://example.com/live.m3u8';
    final neutral = tracker.getScore(url);

    tracker.recordPlaybackSuccess(url);
    final afterSuccess = tracker.getScore(url);
    tracker.recordManualSkip(url);
    final afterSkip = tracker.getScore(url);
    tracker.recordPlaybackSuccess(url);

    expect(afterSuccess, greaterThan(neutral));
    expect(afterSkip, lessThan(afterSuccess));
    expect(tracker.getScore(url), greaterThan(afterSkip));
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
