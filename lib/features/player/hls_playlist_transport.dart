import 'dart:convert';
import 'dart:io';

Uri hlsResponseBase(Uri requested, HttpClientResponse response) => response
    .redirects
    .fold(requested, (uri, redirect) => uri.resolveUri(redirect.location));

/// Keep one delivery session instead of returning to a load-balancing entry
/// point on every live playlist refresh. Renew only when that session fails.
class HlsPlaylistTransport {
  final _targets = <Uri, Uri>{};
  var _generation = 0;

  void clear() {
    _generation++;
    _targets.clear();
  }

  Future<({Uri origin, String body})> read(
    HttpClient client,
    Uri source,
    Map<String, String> headers, {
    int? maxBytes,
  }) async {
    var target = _targets[source] ?? source;
    final generation = _generation;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final request = await client.getUrl(target);
        final sameHost =
            target.host == source.host ||
            target.host.endsWith('.${source.host}');
        for (final entry in headers.entries) {
          if (!sameHost &&
              const {
                'authorization',
                'cookie',
                'www-authenticate',
              }.contains(entry.key.toLowerCase()))
            continue;
          request.headers.set(entry.key, entry.value);
        }
        final response = await request.close().timeout(
          const Duration(seconds: 8),
        );
        if (response.statusCode != 200) {
          await response.listen((_) {}).cancel();
          throw HttpException('HLS manifest ${response.statusCode}');
        }
        var bytes = 0;
        final stream = response.timeout(const Duration(seconds: 8)).map((
          chunk,
        ) {
          bytes += chunk.length;
          if (maxBytes != null && bytes > maxBytes)
            throw const FormatException('HLS manifest exceeds size limit');
          return chunk;
        });
        final body = await utf8.decoder
            .bind(stream)
            .join()
            .timeout(const Duration(seconds: 8));
        final origin = hlsResponseBase(target, response);
        if (generation == _generation) _targets[source] = origin;
        return (origin: origin, body: body);
      } catch (_) {
        if (generation != _generation || target == source || attempt != 0)
          rethrow;
        _targets.remove(source);
        target = source;
      }
    }
    throw const HttpException('HLS session unavailable');
  }
}
