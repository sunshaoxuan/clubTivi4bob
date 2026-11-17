import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../core/server_egress.dart';
import '../../core/app_diagnostics.dart';
import 'hls_linearized_pipe.dart';

const actionMoviesLegacyConfig = 'production-LiveChannel-6065';
const actionMoviesCurrentConfig = 'production-hls-aes128-rtv-6065-playout';

bool isActionMoviesUk(String source) {
  final uri = Uri.tryParse(source);
  return uri?.scheme == 'https' &&
      uri?.host == 'action-rakuten-tv-uk.fast.rakuten.tv' &&
      uri!.userInfo.isEmpty &&
      (uri.path.contains('/$actionMoviesLegacyConfig/') ||
          uri.path.contains('/$actionMoviesCurrentConfig/'));
}

/// A fixed MediaTailor session expires, and the old playback configuration
/// returns 404. Bootstrap a fresh session from the verified AES-128 master.
Uri currentActionMoviesMaster(String source) {
  if (!isActionMoviesUk(source)) {
    throw const FormatException('Unreviewed Action Movies edition');
  }
  return Uri.parse(
    'https://action-rakuten-tv-uk.fast.rakuten.tv/v1/master/'
    '0547f18649bd788bec7b67b746e47670f558b6b2/'
    '$actionMoviesCurrentConfig/master.m3u8',
  );
}

/// Avoid probing every bitrate and experimental HLS WebVTT before video starts.
/// Only reviewed Action UK video renditions can become a playback target.
/// The balanced pilot caps advertised bitrate at 3 Mbps after real 1080p
/// transfers exhausted the live window; do not force the highest bitrate.
Uri selectActionMoviesMedia(
  String body,
  Uri master, {
  int maxBandwidth = 3000000,
}) {
  final lines = const LineSplitter().convert(body);
  Uri? selected;
  var highest = -1;
  Uri? smallest;
  var smallestBandwidth = 1 << 62;
  int? bandwidth;
  for (final raw in lines) {
    final line = raw.trim();
    if (line.startsWith('#EXT-X-STREAM-INF:')) {
      bandwidth = int.tryParse(
        RegExp(r'(?:[:,])BANDWIDTH=(\d+)').firstMatch(line)?[1] ?? '',
      );
    } else if (line.isNotEmpty && !line.startsWith('#')) {
      final candidate = master.resolve(line);
      if (bandwidth != null &&
          isActionMoviesUk(candidate.toString()) &&
          candidate.path.contains('/v1/manifest/') &&
          candidate.path.endsWith('.m3u8') &&
          candidate.userInfo.isEmpty &&
          candidate.port == 443) {
        if (bandwidth < smallestBandwidth) {
          smallestBandwidth = bandwidth;
          smallest = candidate;
        }
        if (bandwidth <= maxBandwidth && bandwidth > highest) {
          highest = bandwidth;
          selected = candidate;
        }
      }
      bandwidth = null;
    }
  }
  selected ??= smallest;
  if (selected == null) {
    throw const FormatException('No reviewed Action UK audio/video rendition');
  }
  return selected;
}

/// Keep a duration-based distance from the live edge, including one-second
/// advert segments. Media and encryption keys continue directly from the CDN.
String rewriteBufferedHls(
  String body,
  Uri origin,
  String Function(Uri) playlistUrl, {
  double holdBackSeconds = 30,
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

class HlsPlaybackSegment {
  HlsPlaybackSegment({
    required this.sequence,
    required this.start,
    required this.end,
    required this.asset,
    required this.movieId,
    required this.ad,
  });
  final int sequence;
  final double start, end;
  final String asset;
  final String? movieId;
  final bool ad;
}

class HlsBufferProxy {
  HlsBufferProxy({this.captureClock = false});
  bool captureClock;
  int _generation = 0;
  final _segments = <String, HlsPlaybackSegment>{};
  final _segmentUris = <String, Uri>{};
  final _sequenceStarts = <int, double>{};
  double? _playbackOrigin;
  HlsPlaybackSegment? segmentAt(double position) {
    final origin = _playbackOrigin;
    if (origin == null) return null;
    for (final segment in _segments.values) {
      if (position >= segment.start - origin &&
          position < segment.end - origin) {
        return HlsPlaybackSegment(
          sequence: segment.sequence,
          start: segment.start - origin,
          end: segment.end - origin,
          asset: segment.asset,
          movieId: segment.movieId,
          ad: segment.ad,
        );
      }
    }
    return null;
  }

  HlsPlaybackSegment? beginSegment(String path) {
    final segment = _segments[path];
    if (segment != null) _playbackOrigin ??= segment.start;
    return segment;
  }

  String indexSegments(
    String body,
    Uri origin,
    String Function(String) localUrl,
  ) {
    final parsedSequence = int.tryParse(
      RegExp(r'#EXT-X-MEDIA-SEQUENCE:(\d+)').firstMatch(body)?[1] ?? '',
    );
    if (parsedSequence == null) return body;
    var sequence = parsedSequence;
    double? duration;
    String? movie;
    var ad = false;
    final lines = <String>[];
    for (final raw in const LineSplitter().convert(body)) {
      var line = raw;
      if (raw.startsWith('#EXT-X-CUE-OUT')) ad = true;
      if (raw.startsWith('#EXT-X-CUE-IN')) ad = false;
      if (raw.startsWith('#EXTINF:')) {
        duration = double.tryParse(raw.substring(8).split(',').first);
        movie = RegExp(r'epid=([^:,\s"]+)').firstMatch(raw)?[1];
      } else if (!raw.startsWith('#') &&
          raw.trim().isNotEmpty &&
          duration != null) {
        final remote = origin.resolve(raw.trim());
        final key = '/segment/$sequence.ts';
        var start = _sequenceStarts[sequence];
        if (start == null) {
          final previous = _segments['/segment/${sequence - 1}.ts'];
          start =
              previous?.end ??
              (_sequenceStarts.isEmpty ? 0 : _segments.values.last.end);
          _sequenceStarts[sequence] = start;
        }
        _segments[key] = HlsPlaybackSegment(
          sequence: sequence,
          start: start,
          end: start + duration,
          asset: remote.path.split('/media-').first,
          movieId: movie,
          ad: ad || movie == null,
        );
        _segmentUris[key] = remote;
        line = localUrl(key);
        sequence++;
        duration = null;
        movie = null;
      }
      lines.add(line);
    }
    if (_segments.length > 1000) {
      final remove = _segments.keys.take(_segments.length - 800).toList();
      for (final key in remove) {
        _sequenceStarts.remove(_segments[key]!.sequence);
        _segments.remove(key);
        _segmentUris.remove(key);
      }
    }
    return lines.join('\n');
  }

  final _linearized = HlsLinearizedPipe();
  bool linearClockReady = false;
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
    _client = client;
    var origin = currentActionMoviesMaster(source);
    if (origin.path.contains('/v1/master/')) {
      try {
        final request = await client.getUrl(origin);
        (headers ?? const <String, String>{}).forEach(request.headers.set);
        final response = await request.close().timeout(
          const Duration(seconds: 8),
        );
        if (response.statusCode != 200) {
          await response.drain<void>();
          throw HttpException(
            'Action UK master returned ${response.statusCode}',
          );
        }
        final bytes = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 8),
        )) {
          bytes.addAll(chunk);
          if (bytes.length > 256 * 1024) {
            throw const FormatException('Action UK master exceeds size limit');
          }
        }
        origin = selectActionMoviesMedia(utf8.decode(bytes), origin);
      } catch (_) {
        client.close(force: true);
        rethrow;
      }
      if (generation != _generation) {
        client.close(force: true);
        return source;
      }
    }
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
        final segment = _segments[request.uri.path];
        final segmentUri = _segmentUris[request.uri.path];
        if (segment != null && segmentUri != null) {
          beginSegment(request.uri.path);
          final remote = await client.getUrl(segmentUri);
          _headers.forEach(remote.headers.set);
          final response = await remote.close().timeout(
            const Duration(seconds: 8),
          );
          request.response.statusCode = response.statusCode;
          request.response.headers.contentType = ContentType('video', 'mp2t');
          request.response.headers.set('Cache-Control', 'no-store');
          // One provider fetch, streamed to the existing decoder on this device.
          await request.response.addStream(
            response.timeout(const Duration(seconds: 12)),
          );
          return;
        }
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
            request.response.write(
              rewriteBufferedHls(
                captureClock
                    ? indexSegments(
                        body,
                        uri,
                        (key) => 'http://127.0.0.1:${_server!.port}$key',
                      )
                    : body,
                uri,
                _register,
              ),
            );
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
    final playlist = _register(origin);
    if (Platform.isMacOS && captureClock) {
      try {
        final media = await _linearized.start(playlist);
        linearClockReady = true;
        return media;
      } on Object catch (error) {
        await _linearized.stop();
        captureClock = false;
        AppDiagnostics.instance.log('client_remux_unavailable', {
          'errorType': error.runtimeType.toString(),
          'providerPlaybackContinues': true,
        });
      }
    }
    return playlist;
  }

  Future<void> stop() async {
    ++_generation;
    await _linearized.stop();
    linearClockReady = false;
    final server = _server;
    _server = null;
    _client?.close(force: true);
    _client = null;
    _sources.clear();
    _segments.clear();
    _segmentUris.clear();
    _sequenceStarts.clear();
    _playbackOrigin = null;
    await server?.close(force: true);
  }
}
