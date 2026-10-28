import 'dart:async';
import 'dart:io';

typedef ResourceNodeProbe = Future<Duration?> Function(Uri base);

/// Selects a resource transport without rewriting catalog or media identities.
/// The same selection is shared by every API, image and package request.
class ResourceNodeRouter {
  ResourceNodeRouter({required this.probe, DateTime Function()? now})
    : now = now ?? DateTime.now;

  static final primary = Uri.parse('https://bobtv.briconbric.com');
  static final relay = Uri.parse('https://cndrp.com/bobtv');
  static const probePath = '/api/v1/resource-node/probe';
  static const probeBytes = 65536;
  static const probeVersion = 'bobtv-resource-v1';
  final ResourceNodeProbe probe;
  final DateTime Function() now;
  Uri _selected = primary;
  DateTime? _expires;
  Future<void>? _probing;
  int _epoch = 0;
  final Map<Uri, DateTime> _unavailable = {};

  Uri get selected => _selected;

  static bool isNode(Uri uri) => canonical(uri) != null;

  static Uri? canonical(Uri uri) {
    if (uri.scheme != 'https' || uri.port != 443 || uri.userInfo.isNotEmpty) {
      return null;
    }
    if (uri.host == primary.host) return uri;
    if (uri.host == relay.host && uri.path.startsWith('/bobtv/')) {
      return uri.replace(host: primary.host, path: uri.path.substring(6));
    }
    return null;
  }

  static bool eligible(Uri uri) {
    final value = canonical(uri);
    if (value == null) return false;
    // Video manifests, segments and downloads never use the resource relay.
    if (value.path == '/api/v1/egress/resource' &&
        value.queryParameters['kind'] == 'media') {
      return false;
    }
    return value.path.startsWith('/api/v1/') ||
        value.path.startsWith('/updates/') ||
        value.path.startsWith('/downloads/') ||
        value.path.startsWith('/assets/') ||
        value.path == '/releases.json';
  }

  static Uri through(Uri canonicalUri, Uri base) => canonicalUri.replace(
    host: base.host,
    path: '${base.path}${canonicalUri.path}',
  );

  Future<void> refresh({bool force = false}) {
    if (!force && _expires != null && now().isBefore(_expires!)) {
      return Future.value();
    }
    return _probing ??= _refresh().whenComplete(() => _probing = null);
  }

  Future<void> _refresh() async {
    final epoch = _epoch;
    Future<Duration?> measure(Uri base) async {
      if (_unavailable[base]?.isAfter(now()) ?? false) return null;
      try {
        return await probe(base).timeout(const Duration(seconds: 3));
      } catch (_) {
        return null;
      }
    }

    final times = await Future.wait([measure(primary), measure(relay)]);
    if (epoch != _epoch) return; // A stale probe cannot undo a newer failure.
    final original = times[0], cached = times[1];
    _selected = cached != null && (original == null || cached < original)
        ? relay
        : primary;
    _expires = now().add(
      original == null && cached == null
          ? const Duration(seconds: 30)
          : const Duration(minutes: 10),
    );
  }

  Future<Uri> resolve(Uri uri) async {
    if (!eligible(uri)) return uri;
    await refresh();
    return through(canonical(uri)!, _selected);
  }

  void failed(Uri uri) {
    _epoch++;
    final base = uri.host == relay.host ? relay : primary;
    _unavailable[base] = now().add(const Duration(minutes: 1));
    _selected = base == relay ? primary : relay;
    _expires = now().add(const Duration(seconds: 30));
  }

  /// Uses a raw, TLS-verified client to avoid recursive routing while probing.
  static Future<Duration?> measure(HttpClient client, Uri base) async {
    final watch = Stopwatch()..start();
    final deadline = Timer(
      const Duration(seconds: 3),
      () => client.close(force: true),
    );
    try {
      final uri = through(primary.resolve(probePath), base);
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 2));
      request.followRedirects = false;
      request.headers.set('Accept-Encoding', 'identity');
      request.headers.set('User-Agent', 'BobTV/1.1 resource-probe');
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      if (response.statusCode != 200 ||
          response.headers.value('x-bobtv-probe') != probeVersion ||
          response.headers.value('x-bobtv-node') !=
              (base == relay ? 'cndrp' : 'origin')) {
        return null;
      }
      var bytes = 0;
      await for (final part in response.timeout(const Duration(seconds: 2))) {
        for (final value in part) {
          // Fixed uncompressed sample; rejects placeholder/error pages.
          if (value != ((bytes * 73 + (bytes >> 8) * 19) & 255)) return null;
          bytes++;
        }
        if (bytes > probeBytes) return null;
      }
      return bytes == probeBytes ? watch.elapsed : null;
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }
}
