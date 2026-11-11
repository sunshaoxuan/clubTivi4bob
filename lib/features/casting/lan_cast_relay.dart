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
    final path = '/$token.ts';
    server.listen((request) async {
      if (request.method != 'GET' ||
          request.uri.path != path ||
          request.connectionInfo?.remoteAddress.address != tvAddress.address) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      try {
        final proxyRequest = await client
            .getUrl(upstream)
            .timeout(const Duration(seconds: 5));
        proxyRequest.followRedirects = false;
        final response = await proxyRequest.close().timeout(
          const Duration(seconds: 10),
        );
        request.response.statusCode = response.statusCode;
        final contentType = response.headers.contentType;
        if (contentType != null) {
          request.response.headers.contentType = contentType;
        }
        request.response.bufferOutput = false;
        await request.response.addStream(response);
      } catch (_) {
        try {
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
