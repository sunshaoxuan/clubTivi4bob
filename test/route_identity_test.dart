import 'package:clubtivi/data/services/route_identity.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/features/player/player_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('endpoint identity preserves meaningful distinctions', () {
    expect(
      canonicalRouteUrl('HTTP://MEDIA.EXAMPLE.ORG:80/live.m3u8?a=1&b=2'),
      'http://media.example.org/live.m3u8?a=1&b=2',
    );
    expect(
      canonicalRouteUrl('https://MEDIA.EXAMPLE.ORG:443'),
      'https://media.example.org/',
    );
    for (final url in [
      'https://media.example.org/live.m3u8?b=2&a=1',
      'https://media.example.org/LIVE.m3u8',
      'http://media.example.org:8080/live.m3u8',
      'https://media.example.org/live%2fm3u8?',
      'https://[2606:4700:4700::1111]/live.m3u8',
    ]) {
      expect(canonicalRouteUrl(url), url);
    }
  });

  test('candidate ranking tries an equivalent endpoint only once', () {
    expect(
      PlayerService.prioritizeCandidateUrls([
        'https://MEDIA.EXAMPLE.ORG:443/live.m3u8',
        'https://media.example.org/live.m3u8',
        'https://media.example.org/other.m3u8',
      ], (_) => .5),
      [
        'https://media.example.org/live.m3u8',
        'https://media.example.org/other.m3u8',
      ],
    );
  });

  test(
    'retirement deletes legacy spellings and prevents rediscovery across providers',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      const canonical = 'https://media.example.org/live.m3u8';
      const variant = 'https://MEDIA.EXAMPLE.ORG:443/live.m3u8';
      try {
        for (final provider in ['github-ai-crawler', 'bobtv-reviewed']) {
          await database.upsertProvider(
            db.ProvidersCompanion.insert(
              id: provider,
              name: provider,
              type: 'm3u',
            ),
          );
        }
        // Raw SQL simulates older clients whose rows predate URL normalization.
        await database.customStatement(
          'INSERT INTO channels(id,provider_id,name,stream_url) VALUES(?,?,?,?)',
          ['legacy-a', 'github-ai-crawler', 'CCTV5+', variant],
        );
        await database.customStatement(
          'INSERT INTO channels(id,provider_id,name,stream_url) VALUES(?,?,?,?)',
          ['legacy-b', 'bobtv-reviewed', 'CCTV5+', canonical],
        );
        expect(
          await database.blockAndDeleteStreamUrl(
            variant,
            reason: 'user_reported_wrong_content',
          ),
          2,
        );
        expect(await database.isStreamUrlBlocked(variant), true);
        expect(await database.isStreamUrlBlocked(canonical), true);
        await database.upsertChannels([
          db.ChannelsCompanion.insert(
            id: 'rediscovered',
            providerId: 'bobtv-reviewed',
            name: 'CCTV5+',
            streamUrl: variant,
          ),
        ]);
        expect(await database.getAllChannels(), isEmpty);
        final events = await database.pendingSharedEvents();
        expect(
          events.where((e) => e['kind'] == 'retire').single['url'],
          canonical,
        );
      } finally {
        await database.close();
      }
    },
  );
}
