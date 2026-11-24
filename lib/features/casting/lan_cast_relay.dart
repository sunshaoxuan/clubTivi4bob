import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Exposes one local playback proxy to one paired television for this session.
class LanCastRelay {
  HttpServer? _server;
  HttpClient? _client;

  Future<String> start(
    Uri upstream,
    String tvHost,
    int tvPort, {
    InternetAddress? localAddress,
  }) async {
    if (upstream.scheme != 'http' ||
        !{'127.0.0.1', 'localhost'}.contains(upstream.host) ||
        upstream.userInfo.isNotEmpty) {
      throw ArgumentError('Relay upstream must be a local HTTP playback proxy');
    }
    final addresses = await InternetAddress.lookup(
      tvHost,
      type: InternetAddressType.IPv4,
    );
    if (addresses.isEmpty) {
      throw const SocketException('TV address unavailable');
    }
    final tvAddress = addresses.first;
    if (localAddress == null) {
      final socket = await Socket.connect(
        tvAddress,
        tvPort,
        timeout: const Duration(seconds: 5),
      );
      localAddress = socket.address;
      socket.destroy();
    }
    await close();
    final server = await HttpServer.bind(localAddress, 0);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    client.autoUncompress = false;
    _server = server;
    _client = client;
    final random = Random.secure();
    final token = List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final extension = RegExp(
      r'\.[a-zA-Z0-9]{1,8}$',
    ).firstMatch(upstream.path)?.group(0);
    // The player's extensionless codec bridge serves MPEG-TS.
    final path = '/$token${extension ?? '.ts'}';
    server.listen((request) async {
      if (!{'GET', 'HEAD'}.contains(request.method) ||
          request.uri.path != path ||
          request.connectionInfo?.remoteAddress.address != tvAddress.address) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      try {
        final proxyRequest = await client
            .openUrl(request.method, upstream)
            .timeout(const Duration(seconds: 5));
        proxyRequest.followRedirects = false;
        proxyRequest.headers.set('accept-encoding', 'identity');
        for (final name in ['range', 'if-range', 'accept-encoding']) {
          final values = request.headers[name];
          if (values != null) proxyRequest.headers.set(name, values);
        }
        final response = await proxyRequest.close().timeout(
          const Duration(seconds: 10),
        );
        if (response.statusCode >= 300 && response.statusCode < 400) {
          await response.listen(null).cancel();
          request.response.statusCode = HttpStatus.badGateway;
          return;
        }
        request.response.statusCode = response.statusCode;
        for (final name in [
          'content-type',
          'content-encoding',
          'content-range',
          'accept-ranges',
          'etag',
          'last-modified',
          'cache-control',
        ]) {
          final values = response.headers[name];
          if (values != null) request.response.headers.set(name, values);
        }
        if (response.contentLength >= 0) {
          request.response.contentLength = response.contentLength;
        }
        request.response.bufferOutput = false;
        if (request.method == 'HEAD') {
          await response.drain<void>();
        } else {
          await request.response.addStream(response);
        }
      } catch (_) {
        try {
          request.response.headers.clear();
          request.response.statusCode = HttpStatus.badGateway;
        } catch (_) {}
      } finally {
        try {
          await request.response.close();
        } catch (_) {}
      }
    });
    return Uri(
      scheme: 'http',
      host: localAddress.address,
      port: server.port,
      path: path,
    ).toString();
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    _client?.close(force: true);
    _client = null;
    await server?.close(force: true);
  }
}
