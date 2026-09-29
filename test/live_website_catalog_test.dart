import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/services/bobtv_api_client.dart';

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
}
