import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../core/server_egress.dart';

bool isActionMoviesUk(String source) {
  final uri = Uri.tryParse(source);
  return uri?.scheme == 'https' &&
      uri?.host == 'action-rakuten-tv-uk.fast.rakuten.tv' &&
      uri!.path.contains('/production-LiveChannel-6065/');
}

/// Keep a duration-based distance from the live edge, including one-second
/// advert segments. Media and encryption keys continue directly from the CDN.
String rewriteBufferedHls(
  String body,
  Uri origin,
  String Function(Uri) playlistUrl, {
  double holdBackSeconds = 24,
}) {
  final durations = RegExp(
    r'#EXTINF:([0-9.]+)',
  ).allMatches(body).map((m) => double.parse(m[1]!)).toList();
  final total = durations.fold<double>(0, (sum, value) => sum + value);
  final target =
      double.tryParse(
        RegExp(r'#EXT-X-TARGETDURATION:([0-9.]+)').firstMatch(body)?[1] ?? '',
      ) ??
      6;
  final live = durations.isNotEmpty && !body.contains('#EXT-X-ENDLIST');
  final lines = <String>[];
  for (final raw in const LineSplitter().convert(body)) {
    if (live && raw.startsWith('#EXT-X-START:')) continue;
    var line = raw;
    if (raw == '#EXTM3U' && live && total > target) {
      final holdBack = holdBackSeconds.clamp(0.0, total - target);
      lines.add(raw);
      lines.add('#EXT-X-START:TIME-OFFSET=-$holdBack,PRECISE=NO');
      continue;
    }
    if (raw.startsWith('#')) {
      line = raw.replaceAllMapped(RegExp(r'URI="([^"]+)"'), (match) {
        final absolute = origin.resolve(match[1]!);
        return 'URI="${absolute.path.endsWith('.m3u8') ? playlistUrl(absolute) : absolute}"';
      });
    } else if (raw.trim().isNotEmpty) {
      final absolute = origin.resolve(raw.trim());
      line = absolute.path.endsWith('.m3u8')
          ? playlistUrl(absolute)
          : absolute.toString();
    }
    lines.add(line);
  }
  return '${lines.join('\n')}\n';
}

class HlsBufferProxy {
  int _generation = 0;
  HttpServer? _server;
  HttpClient? _client;
  final _sources = <String, Uri>{};
  Map<String, String> _headers = const {};
  String _register(Uri uri) {
    final key =
        _sources.entries
            .where((entry) => entry.value == uri)
            .map((entry) => entry.key)
            .firstOrNull ??
        '/${_sources.length}.m3u8';
    if (_sources.length >= 32 && !_sources.containsKey(key)) {
      throw const FormatException('Too many HLS renditions');
    }
    _sources[key] = uri;
    return 'http://127.0.0.1:${_server!.port}$key';
  }

  Future<String> start(String source, Map<String, String>? headers) async {
    await stop();
    if (!isActionMoviesUk(source)) return source;
    final generation = ++_generation;
    _headers = headers ?? const {};
    final client = ServerEgress.createMediaClient();
    client.connectionTimeout = const Duration(seconds: 5);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (generation != _generation) {
      client.close(force: true);
      await server.close(force: true);
      return source;
    }
    _client = client;
    _server = server;
    _server!.listen((request) async {
      try {
        final uri = _sources[request.uri.path];
        if (uri == null) {
          request.response.statusCode = 404;
        } else {
          final remote = await client.getUrl(uri);
          _headers.forEach(remote.headers.set);
          final response = await remote.close().timeout(
            const Duration(seconds: 8),
          );
          request.response.statusCode = response.statusCode;
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
            charset: 'utf-8',
          );
          request.response.headers.set('Cache-Control', 'no-store');
          if (response.statusCode == 200 && generation == _generation) {
            final body = await utf8.decoder
                .bind(response)
                .join()
                .timeout(const Duration(seconds: 8));
            if (generation != _generation) {
              throw const HttpException('HLS session closed');
            }
            request.response.write(rewriteBufferedHls(body, uri, _register));
          } else {
            await response.drain<void>();
          }
        }
      } catch (_) {
        request.response.statusCode = 502;
      } finally {
        try {
          await request.response.close();
        } catch (_) {
          // Switching channel may close the local socket during a response.
        }
      }
    });
    return _register(Uri.parse(source));
  }

  Future<void> stop() async {
    ++_generation;
    final server = _server;
    _server = null;
    _client?.close(force: true);
    _client = null;
    _sources.clear();
    await server?.close(force: true);
  }
}
