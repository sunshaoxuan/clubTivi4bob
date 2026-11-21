import 'dart:io';

import 'package:clubtivi/features/player/hls_buffer_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'failed HLS streams reject partial video and preserve the local server',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      server.listen((request) async {
        if (request.uri.path == '/partial') {
          request.response.contentLength = 4096;
          request.response.add([0x47, 1, 2]);
          await request.response.flush();
          await closeFailedHlsResponse(request.response);
        } else if (request.uri.path == '/unavailable') {
          await closeFailedHlsResponse(request.response);
        } else {
          request.response.write('next segment');
        }
        try {
          await request.response.close();
        } catch (_) {}
      });
      try {
        final origin = 'http://127.0.0.1:${server.port}';
        final partial = await (await client.getUrl(
          Uri.parse('$origin/partial'),
        )).close();
        expect(partial.statusCode, 200);
        await expectLater(partial.drain<void>(), throwsA(isA<HttpException>()));
        final unavailable = await (await client.getUrl(
          Uri.parse('$origin/unavailable'),
        )).close();
        expect(unavailable.statusCode, HttpStatus.badGateway);
        await unavailable.drain<void>();
        final next = await (await client.getUrl(
          Uri.parse('$origin/next'),
        )).close();
        expect(
          await next.fold<List<int>>(
            [],
            (bytes, chunk) => bytes..addAll(chunk),
          ),
          'next segment'.codeUnits,
        );
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    },
  );
}
