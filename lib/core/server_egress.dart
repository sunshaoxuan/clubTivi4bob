import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'resource_node_router.dart';
import 'resource_routing_http_client.dart';

/// One public network boundary. Stored route identities are never rewritten.
class ServerEgress {
  static const origin = 'https://bobtv.briconbric.com';
  static final nodes = ResourceNodeRouter(
    probe: (base) {
      final client = _ServerOnlyHttpOverrides().rawClient(null);
      client.connectionTimeout = const Duration(seconds: 2);
      return ResourceNodeRouter.measure(client, base);
    },
  );
  static const integrationHosts = {
    'api.themoviedb.org',
    'api.trakt.tv',
    'geocoding-api.open-meteo.com',
    'api.open-meteo.com',
    'api.real-debrid.com',
    'api.alldebrid.com',
    'www.premiumize.me',
    'debrid-link.com',
    'offcloud.com',
    'api.put.io',
    'torrentio.strem.fun',
  };

  static bool isServer(Uri uri) => ResourceNodeRouter.isNode(uri);

  static bool isLocal(Uri uri) {
    if (uri.userInfo.isNotEmpty) return false;
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host.endsWith('.local')) return true;
    final ip = InternetAddress.tryParse(host);
    if (ip == null) return false;
    if (ip.isLoopback || ip.isLinkLocal) return true;
    final bytes = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv6) return bytes[0] & 0xfe == 0xfc;
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168);
  }

  static bool canConnect(Uri uri) =>
      isServer(uri) ||
      ((uri.scheme == 'http' ||
              uri.scheme == 'https' ||
              uri.scheme == 'ws' ||
              uri.scheme == 'wss') &&
          isLocal(uri));

  static Uri resourceUri(
    String url,
    String kind, {
    Map<String, dynamic> requestHeaders = const {},
  }) {
    final parts = url.split('|');
    final uri = Uri.tryParse(parts.first.trim());
    if (uri == null || uri.userInfo.isNotEmpty) {
      throw const FormatException('无效的网络资源地址');
    }
    if (kind == 'media') return Uri.parse(mediaUrl(parts.first.trim()));
    if (canConnect(uri)) return uri;
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const FormatException('此线路协议尚未接入服务器转发');
    }
    final parameters = <String, String>{'kind': kind, 'url': uri.toString()};
    final headers = <String, String>{};
    if (parts.length > 1) {
      for (final item in parts.skip(1).join('|').split('&')) {
        final index = item.indexOf('=');
        if (index <= 0) continue;
        final key = item.substring(0, index).toLowerCase();
        if (const {'user-agent', 'referer', 'origin'}.contains(key)) {
          headers[key] = Uri.decodeComponent(item.substring(index + 1));
        }
      }
    }
    for (final entry in requestHeaders.entries) {
      final key = entry.key.toLowerCase();
      if (const {'user-agent', 'referer', 'origin'}.contains(key) &&
          entry.value is String) {
        headers[key] = entry.value as String;
      }
    }
    if (headers.isNotEmpty) parameters['headers'] = jsonEncode(headers);
    return Uri.parse(
      '$origin/api/v1/egress/resource',
    ).replace(queryParameters: parameters);
  }

  static String mediaUrl(String url) {
    final uri = Uri.tryParse(url.split('|').first);
    // Local files and loopback codec bridges are intentional local operations.
    if (uri != null &&
        (uri.scheme == 'file' ||
            !uri.hasScheme ||
            RegExp(r'^[A-Za-z]:[\\/]').hasMatch(url))) {
      return url;
    }
    if (uri == null || uri.userInfo.isNotEmpty) {
      throw const FormatException('无效的视频地址');
    }
    // Unwrap previously stored gateway URLs before handing them to decoders.
    final canonical = ResourceNodeRouter.canonical(uri);
    if (canonical?.path == '/api/v1/egress/resource' &&
        canonical?.queryParameters['kind'] == 'media') {
      return mediaUrl(canonical!.queryParameters['url'] ?? '');
    }
    if (uri.host == ResourceNodeRouter.relay.host &&
        uri.path.startsWith('/bobtv/')) {
      throw const FormatException('资源缓存节点不能作为视频源');
    }
    if (!const {
      'http',
      'https',
      'rtsp',
      'rtmp',
      'rtmps',
      'udp',
      'rtp',
    }.contains(uri.scheme)) {
      throw const FormatException('不支持的视频协议');
    }
    return url.split('|').first.trim();
  }

  static Map<String, String> mediaHeaders(String url) {
    final values = <String, String>{};
    for (final part in url.split('|').skip(1).join('|').split('&')) {
      final index = part.indexOf('=');
      if (index <= 0) continue;
      final key = part.substring(0, index).toLowerCase();
      if (const {'user-agent', 'referer', 'origin'}.contains(key)) {
        final value = Uri.decodeComponent(part.substring(index + 1));
        if (value.length > 2048 || RegExp(r'[\r\n\x00]').hasMatch(value)) {
          throw const FormatException('无效的视频请求头');
        }
        values[key] = value;
      }
    }
    return values;
  }

  static String imageUrl(String url) {
    if (url.isEmpty) return url;
    try {
      return resourceUri(url, 'image').toString();
    } catch (_) {
      return '$origin/api/v1/egress/unavailable-image';
    }
  }

  /// Runs at startup and also covers HTTP requests hidden in dependencies.
  static void installGuard() =>
      HttpOverrides.global = _ServerOnlyHttpOverrides();

  static HttpClient createClient() =>
      _ServerOnlyHttpOverrides().createHttpClient(null);

  /// Explicit node transport for bounded whole-response retries. The same
  /// public-network guard applies; callers cannot reach arbitrary upstreams.
  static HttpClient createPinnedResourceClient() =>
      _ServerOnlyHttpOverrides().rawClient(null);

  static HttpClient createMediaClient() =>
      _ServerOnlyHttpOverrides().rawClient(null, media: true);

  static Dio dio([BaseOptions? options]) {
    final client = Dio(options);
    client.httpClientAdapter = ServerEgressAdapter(
      IOHttpClientAdapter(
        createHttpClient: options?.extra['egressKind'] == 'media'
            ? createMediaClient
            : createClient,
      ),
    );
    return client;
  }
}

class _ServerOnlyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return ResourceRoutingHttpClient(rawClient(context), ServerEgress.nodes);
  }

  HttpClient rawClient(SecurityContext? context, {bool media = false}) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) {
      if (!ServerEgress.canConnect(uri) && !media) {
        throw const SocketException('公共网络请求必须通过 BobTV 服务器');
      }
      return 'DIRECT';
    };
    return client;
  }
}

/// Adapter-level routing happens after authentication/query interceptors.
/// Private integration headers travel inside a TLS POST, never URL/access logs.
class ServerEgressAdapter implements HttpClientAdapter {
  ServerEgressAdapter(this.inner);
  final HttpClientAdapter inner;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final target = options.uri;
    final kind = options.extra['egressKind'] as String? ?? 'data';
    if (kind == 'media') {
      final direct = Uri.parse(ServerEgress.mediaUrl(target.toString()));
      return inner.fetch(
        options.copyWith(
          path: direct.toString(),
          baseUrl: '',
          queryParameters: {},
          followRedirects: true,
        ),
        requestStream,
        cancelFuture,
      );
    }
    if (ServerEgress.canConnect(target)) {
      return inner.fetch(
        options.copyWith(followRedirects: false),
        requestStream,
        cancelFuture,
      );
    }
    if (target.scheme != 'http' && target.scheme != 'https') {
      throw const FormatException('此网络调用尚未接入服务器');
    }
    if (kind != 'data' &&
        (options.method == 'GET' || options.method == 'HEAD')) {
      final gateway = ServerEgress.resourceUri(
        target.toString(),
        kind,
        requestHeaders: options.headers,
      );
      return inner.fetch(
        options.copyWith(
          path: gateway.toString(),
          baseUrl: '',
          queryParameters: {},
          followRedirects: false,
          headers: {
            'Range': options.headers['Range'] ?? options.headers['range'],
            'If-Range':
                options.headers['If-Range'] ?? options.headers['if-range'],
            'User-Agent': 'BobTV/1.0',
          }..removeWhere((key, value) => value == null),
        ),
        null,
        cancelFuture,
      );
    }
    if (target.scheme != 'https' ||
        target.port != 443 ||
        target.userInfo.isNotEmpty ||
        !ServerEgress.integrationHosts.contains(target.host)) {
      throw const FormatException('此服务已停止客户端直连，请使用服务器提供的功能');
    }
    final body = BytesBuilder(copy: false);
    if (requestStream != null) {
      await for (final part in requestStream) {
        body.add(part);
        if (body.length > 256 * 1024) {
          throw const FormatException('服务器请求正文超过限制');
        }
      }
    }
    final encoded = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'url': target.toString(),
          'method': options.method,
          'headers': options.headers.map(
            (key, value) => MapEntry(key, '$value'),
          ),
          'body': base64Encode(body.takeBytes()),
        }),
      ),
    );
    return inner.fetch(
      options.copyWith(
        path: '${ServerEgress.origin}/api/v1/egress/data',
        baseUrl: '',
        method: 'POST',
        queryParameters: {},
        followRedirects: false,
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': encoded.length,
          'User-Agent': 'BobTV/1.0',
        },
      ),
      Stream.value(encoded),
      cancelFuture,
    );
  }

  @override
  void close({bool force = false}) => inner.close(force: force);
}
