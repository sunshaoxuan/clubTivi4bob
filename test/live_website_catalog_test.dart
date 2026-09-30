import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/website_channel_catalog_service.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const runLive = bool.fromEnvironment('BOBTV_LIVE_TEST');
  test('production catalog manifest and snapshot pass client validation',
      () async {
    final api = BobTvApiClient();
    addTearDown(api.close);
    final manifest = await api.fetchChannelCatalogManifest();
    expect(manifest, isNotNull);
    expect(manifest!.channelCount, greaterThan(0));
    expect(manifest.routeCount, greaterThanOrEqualTo(manifest.channelCount));
    final bytes = await api.downloadChannelCatalog(manifest);
    expect(bytes.length, manifest.compressedBytes);
  }, skip: !runLive);

  test('fresh client initializes classified CCTV cards from production', () async {
    SharedPreferences.setMockInitialValues({});
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final service = WebsiteChannelCatalogService(database: database);
    addTearDown(() async { service.dispose(); await database.close(); });
    final imported = await service.sync();
    expect(imported, greaterThan(0), reason: '${service.lastError}');
    final channels = await database.getChannelsForProvider(WebsiteChannelCatalogService.providerId);
    expect(channels.where((row) => row.groupTitle == '中国 / 央视'), isNotEmpty);
    final checks = await database.getAllStreamChecks();
    expect(checks.where((row) => row.lastSuccessAt != null && !row.retired), isNotEmpty);
    print('Fresh client: ${channels.length} shared routes, ${checks.length} verification records');
  }, skip: !runLive);
}
