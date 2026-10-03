import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/bobtv_community_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeApi extends BobTvApiClient {
  List<BobTvReviewedSource> sources = [];
  bool offline = false;
  int reportCount = 0;
  int catalogFetches = 0;

  @override
  Future<List<BobTvReviewedSource>> fetchSources() async {
    catalogFetches++;
    if (offline) throw const BobTvApiException('offline');
    return sources;
  }

  @override
  Future<void> postPlaybackReport({required String sourceId,
      required String fingerprint, required bool playable}) async {
    reportCount++;
  }
}

void main() {
  test('community startup leaves catalog download to shared synchronization', () async {
    SharedPreferences.setMockInitialValues({});
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final api = _FakeApi();
    final service = BobTvCommunityService(database, api: api);
    try {
      await service.start();
      expect(api.catalogFetches, 0);
      await service.refreshCatalog();
      expect(api.catalogFetches, 1);
    } finally {
      service.dispose();
      await database.close();
    }
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('separate reviewed provider keeps local sources during updates', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final api = _FakeApi();
    final service = BobTvCommunityService(database, api: api);
    try {
      await database.upsertProvider(db.ProvidersCompanion.insert(
        id: 'local-user', name: 'My list', type: 'm3u',
      ));
      await database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'local-1', providerId: 'local-user', name: 'Local TV',
          streamUrl: 'https://media.example.com/local.m3u8',
        ),
      ]);
      api.sources = [const BobTvReviewedSource(
        id: 'reviewed-1', name: 'Reviewed TV',
        url: 'https://media.example.com/reviewed.m3u8',
      )];
      await service.refreshCatalog();
      expect(service.state.value.count, 1);
      expect(service.state.value.fresh, isTrue);
      expect((await database.getChannelsForProvider('local-user')).length, 1);
      expect((await database.getChannelsForProvider(
          BobTvCommunityService.providerId)).length, 1);

      api.offline = true;
      await service.refreshCatalog();
      expect(service.state.value.error, isTrue);
      expect(service.state.value.count, 1);
      expect((await database.getChannelsForProvider(
          BobTvCommunityService.providerId)).length, 1);

      await service.reportPlayback(
        channelId: 'bobtv-reviewed:reviewed-1',
        url: 'https://media.example.com/reviewed.m3u8', playable: true,
      );
      expect(api.reportCount, 0);

      api.offline = false;
      api.sources = [];
      await service.refreshCatalog();
      expect(service.state.value.count, 0);
      expect((await database.getChannelsForProvider(
          BobTvCommunityService.providerId)), isEmpty);
      expect((await database.getChannelsForProvider('local-user')).length, 1);
    } finally {
      service.dispose();
      await database.close();
    }
  });
}
