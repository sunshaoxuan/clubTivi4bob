import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/website_channel_catalog_service.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FileCatalogApi extends BobTvApiClient {
  _FileCatalogApi(this.bytes, this.snapshot);
  final List<int> bytes;
  final Map snapshot;
  int get routeCount => (snapshot['channels'] as List).fold(0,
    (total, channel) => total + (channel['routes'] as List).length);
  @override
  Future<List<String>> fetchCatalogBlockedRoutes() async => [];
  @override
  Future<BobTvChannelCatalogManifest?> fetchChannelCatalogManifest() async =>
    BobTvChannelCatalogManifest(version: snapshot['version'] as String,
      channelCount: (snapshot['channels'] as List).length, routeCount: routeCount,
      snapshotPath: '/api/v1/channel-catalog/snapshots/${sha256.convert(bytes)}.json.gz',
      compressedBytes: bytes.length, sha256: sha256.convert(bytes).toString());
  @override
  Future<List<int>> downloadChannelCatalog(BobTvChannelCatalogManifest manifest) async => bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['BOBTV_DIAGNOSTIC_CATALOG'];
  test('public snapshot routes pass the actual client privacy validator', () {
    final snapshot = jsonDecode(utf8.decode(gzip.decode(File(path!).readAsBytesSync()))) as Map;
    final rejected = <Map<String, Object?>>[];
    for (final channel in snapshot['channels'] as List) {
      for (final route in channel['routes'] as List) {
        if (!BobTvApiClient.isPublicCatalogUrl(route['url'] as String)) {
          final uri = Uri.parse(route['url'] as String);
          rejected.add({'channel': channel['name'], 'routeId': route['id'],
            'host': uri.host, 'scheme': uri.scheme, 'pathSegmentCount': uri.pathSegments.length,
            'pathSegmentLengths': uri.pathSegments.map((s) => s.length).toList(),
            'firstSegment': uri.pathSegments.firstOrNull,
            'hasQuery': uri.hasQuery, 'queryKeys': uri.queryParameters.keys.toList(),
            'hasWhitespace': RegExp(r'[\x00-\x20\x7f]').hasMatch(route['url'] as String),
            'hostAddressType': InternetAddress.tryParse(uri.host)?.type.name});
        }
      }
    }
    expect(rejected, isEmpty, reason: jsonEncode(rejected));
  }, skip: path == null ? 'Set BOBTV_DIAGNOSTIC_CATALOG to a verified local snapshot' : false);
  test('verified public snapshot imports through the production client decoder', () async {
    SharedPreferences.setMockInitialValues({});
    final bytes = File(path!).readAsBytesSync();
    final snapshot = jsonDecode(utf8.decode(gzip.decode(bytes))) as Map;
    final api = _FileCatalogApi(bytes, snapshot);
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final service = WebsiteChannelCatalogService(database: database, api: api);
    addTearDown(() async { service.dispose(); await database.close(); });
    expect(await service.sync(), api.routeCount, reason: '${service.lastError}');
    expect(service.state.value.error, isFalse);
    expect(await database.sharedCatalogVersion(), snapshot['version']);
    expect(await database.getAllChannels(), hasLength(api.routeCount));
  }, skip: path == null ? 'Set BOBTV_DIAGNOSTIC_CATALOG to a verified local snapshot' : false);
}
