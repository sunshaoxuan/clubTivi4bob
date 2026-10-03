import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

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

/// Strict client for the public BobTV service. Never sends a media URL in a
/// playback report, and never follows API or download redirects.
class BobTvApiClient {
  BobTvApiClient({HttpClient? httpClient, Uri? baseUri})
    : baseUri = baseUri ?? Uri.parse('https://bobtv.briconbric.com'),
      _client =
          httpClient ??
          (HttpClient()..connectionTimeout = const Duration(seconds: 8));

  final Uri baseUri;
  final HttpClient _client;
  bool _closed = false;

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

  static bool isSafeMediaUrl(String value, {bool candidate = false}) {
    if (value.isEmpty ||
        value.length > 2048 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value))
      return false;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.host.isEmpty ||
        uri.hasFragment)
      return false;
    if (candidate
        ? uri.scheme != 'https'
        : uri.scheme != 'https' && uri.scheme != 'http')
      return false;
    if (InternetAddress.tryParse(uri.host) != null ||
        !uri.host.contains('.') ||
        uri.authority.contains(':'))
      return false;
    final host = uri.host.toLowerCase();
    if (host.endsWith('.local') ||
        host.endsWith('.internal') ||
        host.endsWith('.localhost') ||
        host == 'localhost')
      return false;
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
        ))
      return false;
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
        routes.length > 200)
      throw const FormatException('Invalid inventory');
    final body = utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'fingerprint': fingerprint,
        'routes': routes,
      }),
    );
    if (body.length > 512 * 1024)
      throw const FormatException('Inventory too large');
    final response = await _request(
      'POST',
      '/api/v1/channel-catalog/inventory',
      contentType: 'application/json',
      body: body,
      maxBytes: 4096,
    );
    if (response.status != 202)
      throw BobTvApiException(
        'inventory_http_status',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
    final receipt = jsonDecode(utf8.decode(response.body));
    if (receipt is! Map || receipt['accepted'] is! int) {
      throw const FormatException('Invalid inventory receipt');
    }
    return receipt['accepted'] as int;
  }

  Future<List<Map<String, dynamic>>> uploadChannelEvents({
    required String fingerprint,
    required List<Map<String, Object?>> events,
  }) async {
    if (!fingerprintPattern.hasMatch(fingerprint) ||
        events.isEmpty ||
        events.length > 200)
      throw const FormatException('Invalid sync events');
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
    if (response.status != 202)
      throw BobTvApiException(
        'sync_events_http_status',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
    final payload = jsonDecode(utf8.decode(response.body));
    if (payload is! Map ||
        payload['schemaVersion'] != 1 ||
        payload['receipts'] is! List)
      throw const FormatException('Invalid sync receipts');
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
    if (response.status != 200)
      throw BobTvApiException(
        'blocked_routes_http_status',
        statusCode: response.status,
      );
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

  Future<List<BobTvReviewedSource>> fetchSources() async {
    final response = await _request(
      'GET',
      '/api/v1/sources',
      maxBytes: 4 * 1024 * 1024,
    );
    if (response.status != 200)
      throw BobTvApiException(
        'catalog_http_status',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
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
        decoded['routeCount'] == 0)
      return null;
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
    if (body.length > 512)
      throw const FormatException('Report exceeds 512 bytes');
    final response = await _request(
      'POST',
      '/api/v1/source-reports',
      contentType: 'application/json',
      body: body,
      maxBytes: 4096,
    );
    if (response.status != 202)
      throw BobTvApiException(
        'report_http_status',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
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
    if (response.status != 202)
      throw BobTvApiException(
        'candidate_http_status',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
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

  Future<List<BobTvRelease>> fetchReleases() async {
    final response = await _request(
      'GET',
      '/releases.json',
      maxBytes: 128 * 1024,
    );
    if (response.status != 200)
      throw BobTvApiException(
        'releases_http_status',
        statusCode: response.status,
        retryAfter: response.retryAfter,
      );
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
      final request = await _client
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
    required int maxBytes,
  }) async {
    if (_closed) throw const BobTvApiException('client_closed');
    final request = await _client
        .openUrl(method, _uri(path))
        .timeout(const Duration(seconds: 10));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (contentType != null)
      request.headers.set(HttpHeaders.contentTypeHeader, contentType);
    if (body != null) request.add(body);
    final response = await request.close().timeout(const Duration(seconds: 15));
    final collected = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      if (collected.length + chunk.length > maxBytes) {
        throw const FormatException('API response exceeds limit');
      }
      collected.addAll(chunk);
    }
    return _ApiResponse(
      response.statusCode,
      collected,
      _parseRetryAfter(response.headers.value('retry-after')),
    );
  }

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
