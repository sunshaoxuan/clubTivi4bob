import 'dart:async';

import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/regional_route_service.dart';
import 'package:clubtivi/data/services/stream_health_tracker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;

const domestic = 'https://media.example.org/domestic.m3u8';
const overseas = 'https://media.example.org/overseas.m3u8';

Map<String, dynamic> profile(String country, int asn) => {
  'schemaVersion': 1,
  'countryCode': country,
  'regionCode': '',
  'asn': asn,
  'networkId': '$country:*:$asn',
  'token': '$country-test-token',
  'issuedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
  'expiresAt':
      DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
      1000,
};

class FakeApi extends BobTvApiClient {
  Map<String, dynamic> current = profile('CN', 4134);
  int calls = 0;
  bool offline = false;
  Completer<Map<String, dynamic>>? pendingRanking;

  @override
  Future<Map<String, dynamic>> fetchNetworkProfile() async {
    if (offline) throw StateError('offline');
    return current;
  }

  @override
  Future<Map<String, dynamic>> rankRegionalRoutes(List<String> urls) async {
    calls++;
    if (offline) throw StateError('offline');
    if (pendingRanking != null) return pendingRanking!.future;
    return {
      'schemaVersion': 1,
      'profile': current,
      'routes': [
        for (final url in urls)
          {
            'url': url,
            'score': current['countryCode'] == 'CN'
                ? (url == domestic ? .8 : .2)
                : (url == overseas ? .8 : .2),
          },
      ],
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('same network ranking never rewrites availability or interrupts playback', () async {
    final tracker = StreamHealthTracker();
    final api = FakeApi();
    var networkChanges = 0;
    final service = RegionalRouteService(tracker: tracker, api: api,
      onNetworkChanged: (_) async { networkChanges++; });
    try {
      await service.initialize();
      await service.prepare([domestic]);
      await service.prepare([overseas]);
      expect(networkChanges, 1);
    } finally { service.dispose(); }
  });

  test('late score response from old network is ignored', () async {
    final tracker = StreamHealthTracker();
    final api = FakeApi();
    final service = RegionalRouteService(tracker: tracker, api: api);
    try {
      await service.initialize();
      final old = Map<String, dynamic>.of(api.current);
      api.pendingRanking = Completer<Map<String, dynamic>>();
      final pending = service.prepare([domestic]);
      await Future<void>.delayed(Duration.zero);
      // A concurrent ranking observes the new connection first.
      final first = api.pendingRanking!;
      api.pendingRanking = null;
      api.current = profile('US', 7922);
      await service.prepare([overseas]);
      first.complete({'schemaVersion': 1, 'profile': old,
        'routes': [{'url': domestic, 'score': .99}]});
      await pending;
      expect(service.networkId, 'US:*:7922|direct');
      expect(tracker.getScore(domestic), .5);
    } finally { service.dispose(); }
  });

  test(
    'main and preview share regional ranking and per-channel caching',
    () async {
      final tracker = StreamHealthTracker();
      final api = FakeApi();
      final service = RegionalRouteService(tracker: tracker, api: api);
      try {
        await service.initialize();
        await tracker.prepare([overseas, domestic]);
        expect(tracker.rankUrls([overseas, domestic]).first.key, domestic);
        await tracker.prepare([domestic, overseas]);
        expect(api.calls, 1);
        expect(
          service.observation({'success': 2})['networkToken'],
          api.current['token'],
        );
      } finally {
        service.dispose();
      }
    },
  );

  test(
    'network changes isolate local success, failures and shared scores',
    () async {
      final tracker = StreamHealthTracker();
      await tracker.load();
      tracker.setNetworkContext('CN:GD:4134');
      tracker.setRegionalScores('CN:GD:4134', {domestic: .8, overseas: .2});
      tracker.recordPlaybackSuccess(domestic);
      tracker.recordStall(overseas);
      final cn = tracker.getScore(overseas);
      tracker.setNetworkContext('US:CA:7922');
      expect(tracker.getScore(overseas), .5);
      tracker.setRegionalScores('CN:GD:4134', {overseas: .1});
      expect(tracker.getScore(overseas), .5);
      tracker.setRegionalScores('US:CA:7922', {overseas: .9});
      expect(tracker.getScore(overseas), .9);
      tracker.setNetworkContext('CN:GD:4134');
      expect(tracker.getScore(overseas), lessThan(.5));
      expect(tracker.getScore(overseas), greaterThanOrEqualTo(cn));
    },
  );

  test(
    'regional metrics survive reload without leaking between networks',
    () async {
      final tracker = StreamHealthTracker();
      await tracker.load();
      tracker.setNetworkContext('CN:*:4134');
      tracker.recordStall(domestic);
      await tracker.save();
      final restored = StreamHealthTracker();
      await restored.load();
      restored.setNetworkContext('US:*:7922');
      expect(restored.getScore(domestic), .5);
      restored.setNetworkContext('CN:*:4134');
      expect(restored.getScore(domestic), lessThan(.5));
    },
  );

  test(
    'changing network clears checks while retaining favorites and channels',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      try {
        await database.upsertProvider(
          db.ProvidersCompanion.insert(
            id: 'bobtv-channel-catalog',
            name: 'Public',
            type: 'm3u',
          ),
        );
        await database.upsertChannels([
          db.ChannelsCompanion.insert(
            id: 'news',
            providerId: 'bobtv-channel-catalog',
            name: 'News',
            streamUrl: domestic,
            favorite: const Value(true),
          ),
        ]);
        await database.upsertStreamChecks([
          db.StreamChecksCompanion.insert(
            streamUrl: domestic,
            providerId: 'bobtv-channel-catalog',
            channelId: 'news',
            consecutiveFailures: const Value(4),
            retired: const Value(true),
          ),
        ]);
        expect(await database.switchAvailabilityNetwork('CN:*:4134'), true);
        expect(await database.getAllStreamChecks(), isEmpty);
        expect((await database.getAllChannels()).single.favorite, true);
        await database.upsertStreamChecks([
          db.StreamChecksCompanion.insert(
            streamUrl: domestic,
            providerId: 'bobtv-channel-catalog',
            channelId: 'news',
          ),
        ]);
        expect(await database.switchAvailabilityNetwork('CN:*:4134'), false);
        expect(await database.getAllStreamChecks(), hasLength(1));
        expect(await database.switchAvailabilityNetwork('US:*:7922'), true);
        expect(await database.getAllStreamChecks(), isEmpty);
        expect(await database.getAllChannels(), hasLength(1));
      } finally {
        await database.close();
      }
    },
  );

  test(
    'offline API keeps unknown candidates and backs off repeated requests',
    () async {
      final tracker = StreamHealthTracker();
      final api = FakeApi()..offline = true;
      final service = RegionalRouteService(tracker: tracker, api: api);
      try {
        await service.initialize();
        await tracker.prepare([domestic, overseas]);
        expect(tracker.rankUrls([domestic, overseas]).length, 2);
        expect(tracker.getScore(domestic), .5);
        expect(api.calls, 0);
        expect(
          service.observation({'failure': 1}).containsKey('networkToken'),
          false,
        );
      } finally {
        service.dispose();
      }
    },
  );

  test('ranking waits at most 600ms and emits detailed observations', () async {
    final tracker = StreamHealthTracker();
    final pending = Completer<void>();
    tracker.prepareCandidates = (_) => pending.future;
    final started = DateTime.now();
    await tracker.prepare([domestic]);
    expect(DateTime.now().difference(started).inMilliseconds, lessThan(1200));
    pending.complete();
    final observations = <Map<String, Object?>>[];
    tracker.onRegionalObservation = (_, values) => observations.add(values);
    tracker.recordProbeSuccess(domestic, 250, 900000);
    tracker.recordPlaybackSuccess(domestic);
    tracker.recordManualSkip(domestic);
    tracker.recordStall(domestic);
    expect(observations.map((e) => e['observation']), [
      'probe',
      'playback',
      'manual',
      'stall',
    ]);
    expect(observations.first['bytesPerSecond'], 900000);
    expect(observations[2]['failure'], 1);
  });
}
