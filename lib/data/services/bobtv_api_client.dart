import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../models/device_favorites_snapshot.dart';
import '../models/server_epg_snapshot.dart';
import 'device_favorites_identity.dart';
import '../../core/server_egress.dart';
import '../../core/resource_node_router.dart';
import '../../core/resource_routing_http_client.dart';
import '../../core/app_diagnostics.dart';
import '../../core/app_version.dart';

class BobTvApiException implements Exception {
  const BobTvApiException(this.reason, {this.statusCode, this.retryAfter});

  final String reason;
  final int? statusCode;
  final Duration? retryAfter;

  @override
  String toString() => 'BobTvApiException($reason, status=$statusCode)';
}

class BobTvReviewedSource {
  const BobTvReviewedSource({
    required this.id,
    required this.name,
    required this.url,
    this.recentPlayable = 0,
    this.recentFailed = 0,
  });

  final String id;
  final String name;
  final String url;
  final int recentPlayable;
  final int recentFailed;
}

class BobTvRelease {
  const BobTvRelease({
    required this.version,
    required this.date,
    required this.filename,
    required this.size,
    required this.sha256,
  });

  final String version;
  final String date;
  final String filename;
  final String size;
  final String sha256;
}

class BobTvChannelCatalogManifest {
  const BobTvChannelCatalogManifest({
    required this.version,
    required this.channelCount,
    required this.routeCount,
    required this.snapshotPath,
    required this.compressedBytes,
    required this.sha256,
  });

  final String version;
  final int channelCount;
  final int routeCount;
  final String snapshotPath;
  final int compressedBytes;
  final String sha256;
}

class BobTvRouteState {
  const BobTvRouteState({required this.retiredUrls, this.catalogVersion});
  final Set<String> retiredUrls;
  final String? catalogVersion;
}

/// Strict client for the public BobTV service. Never sends a media URL in a
/// playback report, and never follows API or download redirects.
class BobTvApiClient {
  BobTvApiClient({
    HttpClient? httpClient,
    Uri? baseUri,
    ResourceNodeRouter? router,
    this.openTimeout = const Duration(seconds: 10),
    this.headerTimeout = const Duration(seconds: 15),
    this.bodyTimeout = const Duration(seconds: 15),
    this.recordDiagnostics = true,
  }) : baseUri = baseUri ?? Uri.parse('https://bobtv.briconbric.com'),
       nodeRouter =
           router ??
           (httpClient == null &&
                   (baseUri == null || ResourceNodeRouter.isNode(baseUri))
               ? ServerEgress.nodes
               : null),
       _client =
           httpClient ??
           (ServerEgress.createPinnedResourceClient()
             ..connectionTimeout = const Duration(seconds: 8));

  final Uri baseUri;
  final HttpClient _client;
  final ResourceNodeRouter? nodeRouter;
  final Duration openTimeout, headerTimeout, bodyTimeout;
  final bool recordDiagnostics;
  bool _closed = false;
  Duration? lastSyncRetryAfter;
  bool lastSyncQueued = false;

  static final sourceIdPattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,39}$');
  static final fingerprintPattern = RegExp(r'^[a-f0-9]{64}$');
  static final _shaPattern = RegExp(r'^[a-f0-9]{64}$');
  static final _filenamePattern = RegExp(
    r'^BobTV-[A-Za-z0-9.+_-]+-windows-x64\.zip$',
  );

  void close() {
    _closed = true;
    _client.close(force: true);
  }

  Uri _uri(String path) => baseUri.resolve(path);

  static String endpointClass(String path) {
    if (path.startsWith('/api/v1/diagnostics/')) return 'diagnostics';
    if (path.startsWith('/api/v1/channel-catalog/snapshots/')) {
      return 'catalog_snapshot';
    }
    if (path.startsWith('/api/v1/epg/snapshots/')) return 'epg_snapshot';
    return const {
          '/api/v1/channel-catalog/manifest': 'catalog_manifest',
          '/api/v1/channel-catalog/blocked': 'catalog_blocked',
          '/api/v1/channel-catalog/events': 'catalog_events',
          '/api/v1/channel-catalog/inventory': 'catalog_inventory',
          '/api/v1/channel-catalog/route-state': 'route_state',
          '/api/v1/channel-catalog/network-profile': 'network_profile',
          '/api/v1/channel-catalog/rank': 'route_rank',
          '/api/v1/epg/manifest': 'epg_manifest',
          '/api/v1/device-favorites': 'favorites',
        }[path] ??
        'other_api';
  }

  Map<String, String> _favoriteHeaders(DeviceFavoritesCredential credential) {
    final safeOrigin =
        baseUri.scheme == 'https' &&
        baseUri.host == 'bobtv.briconbric.com' &&
        baseUri.port == 443;
    final testOrigin =
        baseUri.scheme == 'http' &&
        (InternetAddress.tryParse(baseUri.host)?.isLoopback ?? false);
    if ((!safeOrigin && !testOrigin) ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment ||
        !fingerprintPattern.hasMatch(credential.fingerprint) ||
        !DeviceFavoritesIdentity.tokenFormat.hasMatch(credential.token)) {
      throw const FormatException('Invalid private favorite connection');
    }
    return {
      HttpHeaders.authorizationHeader: 'Bearer ${credential.token}',
      'X-BobTV-Device-Fingerprint': credential.fingerprint,
    };
  }

  Future<DeviceFavoritesBackup?> fetchDeviceFavorites({
    required DeviceFavoritesCredential credential,
    int? ifRevision,
  }) async {
    final response = await _request(
      'GET',
      '/api/v1/device-favorites',
      headers: {
        ..._favoriteHeaders(credential),
        if (ifRevision != null && ifRevision > 0)
          HttpHeaders.ifNoneMatchHeader: '"favorites-v1-$ifRevision"',
      },
      maxBytes: 512 * 1024,
      requirePrivate: true,
    );
    if (response.status == 404) {
      final missing = jsonDecode(utf8.decode(response.body));
      if (missing is Map && missing['detail'] == 'No backup for this device') {
        return null;
      }
      throw const BobTvApiException(
        'private_favorites_unavailable',
        statusCode: 404,
      );
    }
    if (response.status == 304 && ifRevision != null && ifRevision > 0) {
      return DeviceFavoritesBackup(revision: ifRevision, snapshot: null);
    }
    if (response.status != 200) {
      throw BobTvApiException(
        'private_favorites_fetch',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
    }
    final value = jsonDecode(utf8.decode(response.body));
    if (value is! Map ||
        value['schemaVersion'] != 1 ||
        value['revision'] is! int ||
        (value['revision'] as int) < 1) {
      throw const FormatException('Invalid private favorite backup');
    }
    return DeviceFavoritesBackup(
      revision: value['revision'] as int,
      snapshot: DeviceFavoritesSnapshot.parse(value['snapshot']),
    );
  }

  Future<int> saveDeviceFavorites({
    required DeviceFavoritesCredential credential,
    required DeviceFavoritesSnapshot snapshot,
    required int baseRevision,
  }) async {
    if (baseRevision < 0 || baseRevision > 9007199254740991) {
      throw const FormatException('Invalid private favorite revision');
    }
    final validated = DeviceFavoritesSnapshot.parse(snapshot.toJson());
    final response = await _request(
      'PUT',
      '/api/v1/device-favorites',
      headers: _favoriteHeaders(credential),
      contentType: 'application/json',
      body: utf8.encode(
        jsonEncode({
          'schemaVersion': 1,
          'baseRevision': baseRevision,
          'snapshot': validated.toJson(),
        }),
      ),
      maxBytes: 4096,
      requirePrivate: true,
    );
    if (response.status != 200) {
      throw BobTvApiException(
        'private_favorites_save',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
    }
    final value = jsonDecode(utf8.decode(response.body));
    if (value is! Map ||
        value['revision'] is! int ||
        (value['revision'] as int) < 1 ||
        value['duplicate'] is! bool) {
      throw const FormatException('Invalid private favorite receipt');
    }
    return value['revision'] as int;
  }

  static bool isSafeMediaUrl(String value, {bool candidate = false}) {
    if (value.isEmpty ||
        value.length > 2048 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      return false;
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.host.isEmpty ||
        uri.hasFragment) {
      return false;
    }
    if (candidate
        ? uri.scheme != 'https'
        : uri.scheme != 'https' && uri.scheme != 'http') {
      return false;
    }
    if (InternetAddress.tryParse(uri.host) != null ||
        !uri.host.contains('.') ||
        uri.authority.contains(':')) {
      return false;
    }
    final host = uri.host.toLowerCase();
    if (host.endsWith('.local') ||
        host.endsWith('.internal') ||
        host.endsWith('.localhost') ||
        host == 'localhost') {
      return false;
    }
    if (candidate && (uri.hasQuery || uri.path.isEmpty || uri.path == '/')) {
      return false;
    }
    return true;
  }

  static bool isPublicCatalogUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        value.length > 2048 ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(value) ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.queryParameters.keys.any(
          (key) => RegExp(
            r'token|password|secret|auth|api.?key',
            caseSensitive: false,
          ).hasMatch(key),
        )) {
      return false;
    }
    final segments = uri.pathSegments;
    if (segments.length >= 4 &&
        const {
          'live',
          'movie',
          'series',
        }.contains(segments.first.toLowerCase())) {
      return false;
    }
    final address = InternetAddress.tryParse(uri.host);
    if (address == null) {
      final host = uri.host.toLowerCase();
      return host.contains('.') &&
          !host.endsWith('.local') &&
          !host.endsWith('.internal') &&
          !host.endsWith('.localhost');
    }
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return false;
    }
    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      return bytes[0] != 0 &&
          bytes[0] != 10 &&
          bytes[0] != 127 &&
          bytes[0] < 224 &&
          !(bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) &&
          !(bytes[0] == 192 && bytes[1] == 168) &&
          !(bytes[0] == 169 && bytes[1] == 254) &&
          !(bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127);
    }
    return bytes[0] >= 0x20 && bytes[0] <= 0x3f;
  }

  Future<int> uploadChannelInventory({
    required String fingerprint,
    required List<Map<String, Object?>> routes,
  }) async {
    if (!fingerprintPattern.hasMatch(fingerprint) ||
        routes.isEmpty ||
        routes.length > 200) {
      throw const FormatException('Invalid inventory');
    }
    final body = utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'fingerprint': fingerprint,
        'routes': routes,
      }),
    );
    if (body.length > 512 * 1024) {
      throw const FormatException('Inventory too large');
    }
    final response = await _request(
      'POST',
      '/api/v1/channel-catalog/inventory',
      contentType: 'application/json',
      body: body,
      maxBytes: 4096,
    );
    if (response.status != 202) {
      throw BobTvApiException(
        'inventory_http_status',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
    }
    final receipt = jsonDecode(utf8.decode(response.body));
    if (receipt is! Map || receipt['accepted'] is! int) {
      throw const FormatException('Invalid inventory receipt');
    }
    return receipt['accepted'] as int;
  }

  Future<Map<String, dynamic>> fetchNetworkProfile() async {
    final response = await _request(
      'GET',
      '/api/v1/channel-catalog/network-profile',
      maxBytes: 4096,
    );
    if (response.status != 200) {
      throw BobTvApiException(
        'network_profile_http_status',
        statusCode: response.status,
      );
    }
    final result = jsonDecode(utf8.decode(response.body));
    if (result is! Map<String, dynamic>) {
      throw const FormatException('Invalid network profile');
    }
    return result;
  }

  Future<Map<String, dynamic>> rankRegionalRoutes(List<String> urls) async {
    if (urls.isEmpty ||
        urls.length > 200 ||
        urls.any((url) => !isPublicCatalogUrl(url))) {
      throw const FormatException('Invalid regional candidates');
    }
    final response = await _request(
      'POST',
      '/api/v1/channel-catalog/rank',
      contentType: 'application/json',
      body: utf8.encode(
        jsonEncode({'schemaVersion': 1, 'urls': urls, 'transport': 'direct'}),
      ),
      maxBytes: 1024 * 1024,
    );
    if (response.status != 200) {
      throw BobTvApiException(
        'regional_ranking_http_status',
        statusCode: response.status,
      );
    }
    final result = jsonDecode(utf8.decode(response.body));
    if (result is! Map<String, dynamic> || result['schemaVersion'] != 1) {
      throw const FormatException('Invalid regional rankings');
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> uploadChannelEvents({
    required String fingerprint,
    required List<Map<String, Object?>> events,
  }) async {
    if (!fingerprintPattern.hasMatch(fingerprint) ||
        events.isEmpty ||
        events.length > 200) {
      throw const FormatException('Invalid sync events');
    }
    final response = await _request(
      'POST',
      '/api/v1/channel-catalog/events',
      contentType: 'application/json',
      body: utf8.encode(
        jsonEncode({
          'schemaVersion': 1,
          'fingerprint': fingerprint,
          'events': events,
        }),
      ),
      maxBytes: 128 * 1024,
    );
    lastSyncRetryAfter = response.retryAfter;
    if (response.status != 202) {
      throw BobTvApiException(
        'sync_events_http_status',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
    }
    final payload = jsonDecode(utf8.decode(response.body));
    if (payload is! Map ||
        payload['schemaVersion'] != 1 ||
        payload['receipts'] is! List) {
      throw const FormatException('Invalid sync receipts');
    }
    lastSyncQueued = payload['queued'] == true;
    return (payload['receipts'] as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
  }

  Future<List<String>> fetchCatalogBlockedRoutes() async {
    final response = await _request(
      'GET',
      '/api/v1/channel-catalog/blocked',
      maxBytes: 8 * 1024 * 1024,
    );
    if (response.status == 404) return const [];
    if (response.status != 200) {
      throw BobTvApiException(
        'blocked_routes_http_status',
        statusCode: response.status,
      );
    }
    final payload = jsonDecode(utf8.decode(response.body));
    if (payload is! Map ||
        payload['schemaVersion'] != 1 ||
        payload['urls'] is! List) {
      throw const FormatException('Invalid blocked routes');
    }
    return (payload['urls'] as List)
        .whereType<String>()
        .where(isPublicCatalogUrl)
        .toList();
  }

  Future<BobTvRouteState> fetchRouteState(List<String> urls) async {
    if (urls.isEmpty || urls.length > 200) {
      throw const FormatException('Invalid route-state batch');
    }
    final response = await _request(
      'POST',
      '/api/v1/channel-catalog/route-state',
      contentType: 'application/json',
      body: utf8.encode(jsonEncode({'schemaVersion': 1, 'urls': urls})),
      maxBytes: 512 * 1024,
    );
    if (response.status != 200) {
      throw BobTvApiException(
        'route_state_http_status',
        statusCode: response.status,
      );
    }
    final payload = jsonDecode(utf8.decode(response.body));
    if (payload is! Map ||
        payload['schemaVersion'] != 1 ||
        payload['urls'] is! List ||
        (payload['catalogVersion'] != null &&
            payload['catalogVersion'] is! String)) {
      throw const FormatException('Invalid route state');
    }
    final retired = (payload['urls'] as List).whereType<String>().toSet();
    if (retired.length != (payload['urls'] as List).length ||
        retired.any((url) => !urls.contains(url))) {
      throw const FormatException('Unrequested retirement');
    }
    return BobTvRouteState(
      retiredUrls: retired,
      catalogVersion: payload['catalogVersion'] as String?,
    );
  }

  Future<List<BobTvReviewedSource>> fetchSources() async {
    final response = await _request(
      'GET',
      '/api/v1/sources',
      maxBytes: 4 * 1024 * 1024,
    );
    if (response.status != 200) {
      throw BobTvApiException(
        'catalog_http_status',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
    }
    final decoded = jsonDecode(utf8.decode(response.body));
    final raw = decoded is Map ? decoded['sources'] : null;
    if (raw is! List || raw.length > 10000) {
      throw const FormatException('Invalid reviewed-source catalog');
    }
    final result = <BobTvReviewedSource>[];
    final seen = <String>{};
    for (final item in raw) {
      if (item is! Map ||
          item['id'] is! String ||
          item['name'] is! String ||
          item['url'] is! String) {
        throw const FormatException('Invalid reviewed-source entry');
      }
      final id = item['id'] as String;
      final name = item['name'] as String;
      final url = item['url'] as String;
      if (!sourceIdPattern.hasMatch(id) ||
          !seen.add(id) ||
          name.isEmpty ||
          name.length > 64 ||
          !isSafeMediaUrl(url)) {
        throw const FormatException('Invalid reviewed-source fields');
      }
      final feedback = item['feedback'];
      final playable = feedback is Map && feedback['recentPlayable'] is int
          ? feedback['recentPlayable'] as int
          : 0;
      final failed = feedback is Map && feedback['recentFailed'] is int
          ? feedback['recentFailed'] as int
          : 0;
      result.add(
        BobTvReviewedSource(
          id: id,
          name: name,
          url: url,
          recentPlayable: playable < 0 ? 0 : playable,
          recentFailed: failed < 0 ? 0 : failed,
        ),
      );
    }
    return result;
  }

  Future<ServerEpgManifest?> fetchEpgManifest() async {
    final response = await _request(
      'GET',
      '/api/v1/epg/manifest',
      headers: const {
        'Cache-Control': 'no-cache, no-store, max-age=0',
        'Pragma': 'no-cache',
      },
      maxBytes: 4096,
    );
    if (response.status != 200) {
      throw BobTvApiException(
        'epg_manifest_status',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
    }
    return ServerEpgManifest.parse(jsonDecode(utf8.decode(response.body)));
  }

  Future<List<int>> downloadEpgSnapshot(ServerEpgManifest manifest) async {
    final response = await _request(
      'GET',
      manifest.snapshotPath,
      maxBytes: 8 * 1024 * 1024,
    );
    if (response.status != 200) {
      throw BobTvApiException(
        'epg_snapshot_status',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
    }
    if (response.body.length != manifest.compressedBytes ||
        sha256.convert(response.body).toString() != manifest.sha256) {
      throw const FormatException('EPG snapshot checksum mismatch');
    }
    return response.body;
  }

  Future<BobTvChannelCatalogManifest?> fetchChannelCatalogManifest() async {
    final response = await _request(
      'GET',
      '/api/v1/channel-catalog/manifest',
      maxBytes: 4096,
    );
    if (response.status != 200) {
      throw BobTvApiException(
        'channel_catalog_manifest_status',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
    }
    final decoded = jsonDecode(utf8.decode(response.body));
    if (decoded is! Map || decoded['schemaVersion'] != 1) {
      throw const FormatException('Unsupported channel catalog manifest');
    }
    if (decoded['version'] == null &&
        decoded['channelCount'] == 0 &&
        decoded['routeCount'] == 0) {
      return null;
    }
    final version = decoded['version'];
    final channelCount = decoded['channelCount'];
    final routeCount = decoded['routeCount'];
    final path = decoded['snapshotUrl'];
    final compressedBytes = decoded['compressedBytes'];
    final digest = decoded['sha256'];
    if (version is! String ||
        version.isEmpty ||
        version.length > 80 ||
        channelCount is! int ||
        channelCount < 0 ||
        channelCount > 10000 ||
        routeCount is! int ||
        routeCount < channelCount ||
        routeCount > 100000 ||
        compressedBytes is! int ||
        compressedBytes < 1 ||
        compressedBytes > 32 * 1024 * 1024 ||
        digest is! String ||
        !_shaPattern.hasMatch(digest) ||
        path != '/api/v1/channel-catalog/snapshots/$digest.json.gz') {
      throw const FormatException('Invalid channel catalog manifest');
    }
    return BobTvChannelCatalogManifest(
      version: version,
      channelCount: channelCount,
      routeCount: routeCount,
      snapshotPath: path as String,
      compressedBytes: compressedBytes,
      sha256: digest,
    );
  }

  Future<List<int>> downloadChannelCatalog(
    BobTvChannelCatalogManifest manifest,
  ) async {
    if (!_shaPattern.hasMatch(manifest.sha256) ||
        manifest.snapshotPath !=
            '/api/v1/channel-catalog/snapshots/${manifest.sha256}.json.gz') {
      throw const FormatException('Invalid catalog snapshot path');
    }
    final response = await _request(
      'GET',
      manifest.snapshotPath,
      maxBytes: 32 * 1024 * 1024,
    );
    if (response.status != 200) {
      throw BobTvApiException(
        'channel_catalog_snapshot_status',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
    }
    if (response.body.length != manifest.compressedBytes ||
        sha256.convert(response.body).toString() != manifest.sha256) {
      throw const FormatException('Channel catalog checksum mismatch');
    }
    return response.body;
  }

  Future<void> postPlaybackReport({
    required String sourceId,
    required String fingerprint,
    required bool playable,
  }) async {
    if (!sourceIdPattern.hasMatch(sourceId) ||
        !fingerprintPattern.hasMatch(fingerprint)) {
      throw const FormatException('Invalid playback report');
    }
    final body = utf8.encode(
      jsonEncode({
        'sourceId': sourceId,
        'fingerprint': fingerprint,
        'playable': playable,
      }),
    );
    if (body.length > 512) {
      throw const FormatException('Report exceeds 512 bytes');
    }
    final response = await _request(
      'POST',
      '/api/v1/source-reports',
      contentType: 'application/json',
      body: body,
      maxBytes: 4096,
    );
    if (response.status != 202) {
      throw BobTvApiException(
        'report_http_status',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
    }
  }

  Future<String> submitCandidate({
    required String name,
    required String url,
    required String device,
    required String fingerprint,
    required bool consent,
  }) async {
    const devices = {'Windows', 'Android', 'iOS', 'macOS', 'Linux', 'Other'};
    if (name.runes.isEmpty ||
        name.runes.length > 64 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
        !isSafeMediaUrl(url, candidate: true) ||
        !devices.contains(device) ||
        !fingerprintPattern.hasMatch(fingerprint) ||
        !consent) {
      throw const FormatException('Candidate does not meet submission rules');
    }
    final body = utf8.encode(
      jsonEncode({
        'name': name,
        'url': url,
        'device': device,
        'fingerprint': fingerprint,
        'consent': true,
      }),
    );
    if (body.length > 4096) {
      throw const FormatException('Candidate exceeds 4096 bytes');
    }
    final response = await _request(
      'POST',
      '/api/v1/source-candidates',
      contentType: 'application/json',
      body: body,
      maxBytes: 4096,
    );
    if (response.status != 202) {
      throw BobTvApiException(
        'candidate_http_status',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
    }
    final decoded = jsonDecode(utf8.decode(response.body));
    if (decoded is! Map ||
        decoded['pendingReview'] != true ||
        decoded['id'] is! String) {
      throw const FormatException('Invalid candidate receipt');
    }
    return decoded['id'] as String;
  }

  Future<bool> uploadLogSnapshot(List<int> ndjson) async {
    if (ndjson.isEmpty || ndjson.length > 1024 * 1024) {
      throw const FormatException('Log snapshot exceeds limit');
    }
    final response = await _request(
      'POST',
      '/api/v1/logs',
      contentType: 'application/x-ndjson',
      body: ndjson,
      maxBytes: 4096,
    );
    if (response.status != 200 && response.status != 201) {
      throw BobTvApiException(
        'logs_http_status',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
    }
    final decoded = jsonDecode(utf8.decode(response.body));
    if (decoded is! Map ||
        decoded['id'] is! String ||
        !_shaPattern.hasMatch(decoded['id'] as String) ||
        decoded['duplicate'] is! bool) {
      throw const FormatException('Invalid log receipt');
    }
    return decoded['duplicate'] as bool;
  }

  Future<Map<String, dynamic>> uploadDiagnosticBatch(
    List<int> body, {
    Uri? node,
  }) async {
    if (body.isEmpty || body.length > 256 * 1024) {
      throw const FormatException('Diagnostic batch limit');
    }
    final result = await _request(
      'POST',
      '/api/v1/diagnostics/batches',
      body: body,
      contentType: 'application/json',
      maxBytes: 4096,
      nodeOverride: node,
    );
    if (!{200, 201, 202}.contains(result.status)) {
      throw BobTvApiException(
        'diagnostics_upload',
        statusCode: result.status,
        retryAfter: result.retryAfter,
      );
    }
    final value = jsonDecode(utf8.decode(result.body));
    if (value is! Map<String, dynamic> ||
        value['id'] != sha256.convert(body).toString() ||
        !{
          'relay_stored',
          'origin_accepted',
          'rejected',
        }.contains(value['state'])) {
      throw const FormatException('Invalid diagnostic receipt');
    }
    return value;
  }

  Future<Map<String, dynamic>?> diagnosticReceipt(
    String digest, {
    Uri? node,
  }) async {
    if (!_shaPattern.hasMatch(digest)) {
      throw const FormatException('Invalid diagnostic ID');
    }
    final result = await _request(
      'GET',
      '/api/v1/diagnostics/batches/$digest',
      maxBytes: 4096,
      nodeOverride: node,
    );
    if (result.status == 404) return null;
    if (result.status != 200) {
      throw BobTvApiException(
        'diagnostics_receipt',
        statusCode: result.status,
        retryAfter: result.retryAfter,
      );
    }
    final value = jsonDecode(utf8.decode(result.body));
    if (value is! Map<String, dynamic> ||
        value['id'] != digest ||
        !{
          'relay_stored',
          'origin_accepted',
          'rejected',
        }.contains(value['state'])) {
      throw const FormatException('Invalid diagnostic receipt');
    }
    return value;
  }

  Future<List<BobTvRelease>> fetchReleases() async {
    final response = await _request(
      'GET',
      '/releases.json',
      maxBytes: 128 * 1024,
    );
    if (response.status != 200) {
      throw BobTvApiException(
        'releases_http_status',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
    }
    final decoded = jsonDecode(utf8.decode(response.body));
    final raw = decoded is Map ? decoded['releases'] : null;
    if (raw is! List || raw.length > 100) {
      throw const FormatException('Invalid releases catalog');
    }
    return raw.map((item) {
      if (item is! Map ||
          item['version'] is! String ||
          item['date'] is! String ||
          item['filename'] is! String ||
          item['size'] is! String ||
          item['sha256'] is! String ||
          !_filenamePattern.hasMatch(item['filename'] as String) ||
          !_shaPattern.hasMatch(item['sha256'] as String)) {
        throw const FormatException('Invalid release entry');
      }
      return BobTvRelease(
        version: item['version'] as String,
        date: item['date'] as String,
        filename: item['filename'] as String,
        size: item['size'] as String,
        sha256: item['sha256'] as String,
      );
    }).toList();
  }

  Future<File> downloadRelease(
    BobTvRelease release,
    Directory directory,
  ) async {
    if (!_filenamePattern.hasMatch(release.filename) ||
        !_shaPattern.hasMatch(release.sha256)) {
      throw const FormatException('Invalid release metadata');
    }
    await directory.create(recursive: true);
    final finalFile = File(p.join(directory.path, release.filename));
    if (await finalFile.exists() &&
        (await sha256.bind(finalFile.openRead()).first).toString() ==
            release.sha256) {
      return finalFile;
    }
    final temporary = File('${finalFile.path}.part');
    if (await temporary.exists()) await temporary.delete();
    try {
      final downloadClient = nodeRouter == null
          ? _client
          : ResourceRoutingHttpClient(_client, nodeRouter!);
      final request = await downloadClient
          .getUrl(_uri('/downloads/${release.filename}'))
          .timeout(const Duration(seconds: 10));
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw BobTvApiException(
          'download_http_status',
          statusCode: response.statusCode,
        );
      }
      final sink = temporary.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          received += chunk.length;
          if (_closed || received > 1024 * 1024 * 1024) {
            throw const FormatException('Download canceled or too large');
          }
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      final digest = await sha256.bind(temporary.openRead()).first;
      if (digest.toString() != release.sha256) {
        throw const FormatException('Release SHA-256 mismatch');
      }
      if (await finalFile.exists()) await finalFile.delete();
      return temporary.rename(finalFile.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<_ApiResponse> _request(
    String method,
    String path, {
    String? contentType,
    List<int>? body,
    Map<String, String> headers = const {},
    bool requirePrivate = false,
    Uri? nodeOverride,
    required int maxBytes,
  }) async {
    if (_closed) throw const BobTvApiException('client_closed');
    if (nodeOverride != null &&
        nodeOverride != ResourceNodeRouter.primary &&
        nodeOverride != ResourceNodeRouter.relay) {
      throw const FormatException('Unapproved resource node');
    }
    final canonical = _uri(path);
    for (var attempt = 0; attempt < 2; attempt++) {
      var target = nodeOverride == null
          ? await nodeRouter?.resolve(canonical) ?? canonical
          : ResourceNodeRouter.through(canonical, nodeOverride);
      HttpClientRequest? request;
      var phase = 'open';
      var openExpired = false;
      var received = 0;
      final watch = Stopwatch()..start();
      final requestId = _requestId();
      final nodeName = target.host == ResourceNodeRouter.relay.host
          ? 'cndrp'
          : target.host == ResourceNodeRouter.primary.host
          ? 'origin'
          : 'local';
      void trace({String? code, int? status}) {
        // No URL, headers, payload, raw exception, device ID or channel name.
        // Uploading diagnostics never recursively creates another upload log.
        if (!recordDiagnostics || endpointClass(path) == 'diagnostics') return;
        AppDiagnostics.instance.log('network_request', {
          'requestId': requestId,
          'endpoint': endpointClass(path),
          'node': nodeName,
          'phase': phase,
          'attempt': attempt + 1,
          'elapsedMs': watch.elapsedMilliseconds,
          'bytes': received,
          'errorCode': ?code,
          'httpStatus': ?status,
        });
      }

      try {
        final opening = _client.openUrl(method, target).then((value) {
          if (openExpired || _closed) {
            value.abort(const HttpException('Request expired'));
          }
          return value;
        });
        request = await opening.timeout(
          openTimeout,
          onTimeout: () {
            openExpired = true;
            throw TimeoutException('Resource open deadline');
          },
        );
        if (_closed) throw const BobTvApiException('client_closed');
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, 'BobTV/$bobTvVersion');
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        request.headers.set('X-BobTV-Request-ID', requestId);
        headers.forEach(request.headers.set);
        if (contentType != null) {
          request.headers.set(HttpHeaders.contentTypeHeader, contentType);
        }
        if (body != null) request.add(body);
        phase = 'headers';
        final response = await request.close().timeout(headerTimeout);
        final retryAfter = _parseRetryAfter(
          response.headers.value('retry-after'),
        );
        phase = 'body';
        final collected = <int>[];
        await for (final chunk in response.timeout(bodyTimeout)) {
          if (watch.elapsed > const Duration(seconds: 60)) {
            throw TimeoutException('Resource total deadline');
          }
          if (collected.length + chunk.length > maxBytes) {
            throw const FormatException('API response exceeds limit');
          }
          collected.addAll(chunk);
          received += chunk.length;
        }
        if (requirePrivate) {
          final cache =
              response.headers.value('cache-control')?.toLowerCase() ?? '';
          final vary = (response.headers.value('vary') ?? '')
              .toLowerCase()
              .split(',')
              .map((s) => s.trim())
              .toSet();
          if (!cache.split(',').map((s) => s.trim()).contains('no-store') ||
              !vary.containsAll({
                'authorization',
                'x-bobtv-device-fingerprint',
              })) {
            throw BobTvApiException(
              'private_favorites_cache_policy',
              statusCode: response.statusCode,
            );
          }
        }
        phase = 'complete';
        if (endpointClass(path) == 'diagnostics' &&
            {200, 201, 202}.contains(response.statusCode) &&
            !(response.headers.value('cache-control') ?? '')
                .toLowerCase()
                .contains('no-store')) {
          throw const FormatException('Diagnostic receipts must not be cached');
        }
        trace(status: response.statusCode);
        // Retry-After describes origin backpressure, not a broken node. Writes
        // are never blindly replayed after sending an authenticated payload.
        if (attempt == 0 &&
            nodeOverride == null &&
            nodeRouter != null &&
            {'GET', 'HEAD'}.contains(method) &&
            retryAfter == null &&
            {502, 503, 504}.contains(response.statusCode)) {
          nodeRouter!.failed(target);
          continue;
        }
        return _ApiResponse(response.statusCode, collected, retryAfter);
      } catch (error) {
        request?.abort(error);
        final transport =
            error is TimeoutException ||
            error is SocketException ||
            error is HandshakeException ||
            error is HttpException;
        final code = error is TimeoutException
            ? 'timeout'
            : error is SocketException
            ? 'socket'
            : error is HandshakeException
            ? 'tls'
            : error is HttpException
            ? 'http'
            : error is FormatException
            ? 'format'
            : 'other';
        trace(code: code);
        if (transport &&
            !_closed &&
            nodeRouter != null &&
            ResourceNodeRouter.eligible(target)) {
          nodeRouter!.failed(target);
          if (attempt == 0 &&
              nodeOverride == null &&
              ({'GET', 'HEAD'}.contains(method) || request == null)) {
            continue;
          }
        }
        rethrow;
      }
    }
    throw const BobTvApiException('resource_attempts_exhausted');
  }

  static String _requestId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static final _random = math.Random.secure();

  static Duration? _parseRetryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null && seconds >= 0) return Duration(seconds: seconds);
    try {
      final date = HttpDate.parse(value);
      final delay = date.difference(DateTime.now().toUtc());
      return delay.isNegative ? Duration.zero : delay;
    } catch (_) {
      return null;
    }
  }
}

class _ApiResponse {
  const _ApiResponse(this.status, this.body, this.retryAfter);
  final int status;
  final List<int> body;
  final Duration? retryAfter;
}
