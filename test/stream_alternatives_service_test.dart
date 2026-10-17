import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/stream_alternatives_service.dart';
import 'package:clubtivi/data/services/stream_health_tracker.dart';
import 'package:clubtivi/data/services/source_visibility.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'package:clubtivi/data/services/server_epg_binding.dart';
import 'package:clubtivi/data/services/website_channel_catalog_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late db.AppDatabase database;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  test('public routes use server identities and never merge equal or normalized names', () async {
    const provider = WebsiteChannelCatalogService.providerId;
    await database.upsertProvider(db.ProvidersCompanion.insert(
      id: provider, name: 'Server catalogue', type: 'catalog'));
    final names = ['Exact Server Name A', 'Different Server Label', 'Exact Server Name A'];
    await database.upsertChannels([
      for (var index = 0; index < 3; index++)
        db.ChannelsCompanion.insert(id: '$provider:r$index', providerId: provider,
          name: names[index], streamUrl: 'https://example.com/public/$index'),
    ]);
    await ServerEpgBinding(database).replaceCatalogIdentities('v1', [
      for (var index = 0; index < 3; index++) {
        'routeId': 'r$index', 'catalogChannelId': index == 2 ? 'server-b' : 'server-a',
        'catalogIdentityHash': 'a' * 64, 'name': names[index], 'group': '中国 / 央视',
      },
    ]);
    final service = StreamAlternativesService(database, StreamHealthTracker());
    await service.rebuild();
    expect(service.getAlternatives(channelId: '$provider:r0',
      channelName: names[0], excludeUrl: 'https://example.com/public/0'),
      ['https://example.com/public/1']);
    expect((await database.getAllChannels()).map((c) => c.name), names);
    expect(await database.publicCatalogChannelIds(['$provider:r0', '$provider:r2']),
      {'$provider:r0': 'server-a', '$provider:r2': 'server-b'});
    await database.addChannelToDefaultFavorites('$provider:r0');
    expect(await database.getAllFavoritedChannelIds(), {'$provider:r0', '$provider:r1'});
  });

  test('public route without server identity does not guess by channel name', () async {
    const provider = WebsiteChannelCatalogService.providerId;
    await database.upsertProvider(db.ProvidersCompanion.insert(
      id: provider, name: 'Server catalogue', type: 'catalog'));
    await database.upsertChannels([
      for (var index = 0; index < 2; index++)
        db.ChannelsCompanion.insert(id: '$provider:r$index', providerId: provider,
          name: 'CCTV-2', streamUrl: 'https://example.com/unbound/$index'),
    ]);
    final service = StreamAlternativesService(database, StreamHealthTracker());
    await service.rebuild();
    expect(service.getAlternatives(channelId: '$provider:r0',
      channelName: 'CCTV-2', excludeUrl: 'https://example.com/unbound/0'), isEmpty);
  });

  test('background rebuild yields and retains playing route index until atomic swap', () async {
    await database.upsertProvider(db.ProvidersCompanion.insert(
      id: 'source', name: 'Test', type: 'm3u'));
    await database.upsertChannels([
      for (var index = 0; index < 250; index++)
        db.ChannelsCompanion.insert(id: 'c$index', providerId: 'source',
          name: 'CCTV-2', streamUrl: 'https://example.com/cctv2/$index.m3u8'),
    ]);
    final rows = await database.getAllChannels();
    final service = StreamAlternativesService(database, StreamHealthTracker());
    await service.rebuildForChannels(rows.take(2).toList());
    List<String> alternatives() => service.getAlternatives(channelId: 'c0',
      channelName: 'CCTV-2', excludeUrl: 'https://example.com/cctv2/0.m3u8');
    final old = alternatives();
    expect(old, hasLength(1));
    var ticks = 0;
    final tick = Timer.periodic(const Duration(milliseconds: 1), (_) => ticks++);
    final refresh = service.rebuildForChannels(rows);
    expect(alternatives(), old);
    await refresh;
    tick.cancel();
    expect(ticks, greaterThan(0));
    expect(alternatives(), hasLength(249));
  });

  test(
    'keeps a mislabeled CCTV5 Plus route out of CCTV5 alternatives',
    () async {
      await database.upsertProvider(
        db.ProvidersCompanion.insert(
          id: 'source',
          name: 'Test source',
          type: 'm3u',
        ),
      );
      await database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'cctv5-main',
          providerId: 'source',
          name: 'CCTV-5',
          tvgName: const Value('CCTV5'),
          streamUrl: 'https://example.com/cctv5-main.m3u8',
        ),
        db.ChannelsCompanion.insert(
          id: 'cctv5-alt',
          providerId: 'source',
          name: 'CCTV5 体育',
          streamUrl: 'https://example.com/cctv5-alt.m3u8',
        ),
        db.ChannelsCompanion.insert(
          id: 'cctv5plus-bad-metadata',
          providerId: 'source',
          name: 'CCTV-5+',
          tvgName: const Value('CCTV5[720][S]'),
          streamUrl: 'https://example.com/cctv5plus.m3u8',
        ),
        db.ChannelsCompanion.insert(
          id: 'cctv5-bad-route',
          providerId: 'source',
          name: 'CCTV-5',
          tvgName: const Value('CCTV5'),
          streamUrl: 'https://example.com/live/cctv5p.m3u8',
        ),
        db.ChannelsCompanion.insert(
          id: 'cctv5-4k-main',
          providerId: 'source',
          name: 'CCTV5 4K',
          streamUrl: 'https://example.com/cctv5-4k-main.m3u8',
        ),
        db.ChannelsCompanion.insert(
          id: 'cctv5-4k-alt',
          providerId: 'source',
          name: 'CCTV5 UHD',
          streamUrl: 'https://example.com/cctv5-4k-alt.m3u8',
        ),
      ]);

      final service = StreamAlternativesService(
        database,
        StreamHealthTracker(),
      );
      await service.rebuild();

      final alternatives = service.getAlternatives(
        channelId: 'cctv5-main',
        channelName: 'CCTV-5',
        originalName: 'CCTV-5',
        excludeUrl: 'https://example.com/cctv5-main.m3u8',
      );
      final details = service.getAlternativeDetails(
        channelId: 'cctv5-main',
        channelName: 'CCTV-5',
        originalName: 'CCTV-5',
        excludeUrl: 'https://example.com/cctv5-main.m3u8',
      );

      expect(alternatives, contains('https://example.com/cctv5-alt.m3u8'));
      expect(
        alternatives,
        isNot(contains('https://example.com/cctv5plus.m3u8')),
      );
      expect(
        alternatives,
        isNot(contains('https://example.com/live/cctv5p.m3u8')),
      );
      expect(
        details.map((detail) => detail.channel.streamUrl),
        isNot(contains('https://example.com/cctv5plus.m3u8')),
      );

      final ultraHdAlternatives = service.getAlternatives(
        channelId: 'cctv5-4k-main',
        channelName: 'CCTV5 4K',
        originalName: 'CCTV5 4K',
        excludeUrl: 'https://example.com/cctv5-4k-main.m3u8',
      );
      expect(
        ultraHdAlternatives,
        contains('https://example.com/cctv5-4k-alt.m3u8'),
      );
      expect(
        ultraHdAlternatives,
        isNot(contains('https://example.com/cctv5-alt.m3u8')),
      );
    },
  );

  test(
    'removes IPv6 providers from automatic alternatives when hidden',
    () async {
      await database.upsertProvider(
        db.ProvidersCompanion.insert(
          id: 'source-ipv4',
          name: 'IPv4 source',
          type: 'm3u',
        ),
      );
      await database.upsertProvider(
        db.ProvidersCompanion.insert(
          id: 'source-ipv6',
          name: '混合线路',
          type: 'm3u',
        ),
      );
      await database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'main',
          providerId: 'source-ipv4',
          name: '湖南卫视',
          streamUrl: 'https://example.com/ipv4.m3u8',
        ),
        db.ChannelsCompanion.insert(
          id: 'ipv6-alt',
          providerId: 'source-ipv6',
          name: '湖南卫视',
          streamUrl: 'https://example.com/ipv6.m3u8',
        ),
      ]);

      final service = StreamAlternativesService(
        database,
        StreamHealthTracker(),
      );
      await service.rebuild();
      expect(
        service.getAlternatives(
          channelId: 'main',
          channelName: '湖南卫视',
          excludeUrl: 'https://example.com/ipv4.m3u8',
        ),
        contains('https://example.com/ipv6.m3u8'),
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(SourceVisibility.hideIpv6PreferenceKey, true);
      await service.rebuild();
      expect(
        service.getAlternatives(
          channelId: 'main',
          channelName: '湖南卫视',
          excludeUrl: 'https://example.com/ipv4.m3u8',
        ),
        isNot(contains('https://example.com/ipv6.m3u8')),
      );
    },
  );
}
