import 'dart:io';
import 'dart:convert';

import 'package:clubtivi/features/player/hls_buffer_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'redirected playlists fetch relative keys and video from the final directory',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      server.listen((request) async {
        final response = request.response;
        switch (request.uri.path) {
          case '/entry/start.m3u8':
            await response.redirect(Uri.parse('../handoff/next.m3u8'));
          case '/handoff/next.m3u8':
            await response.redirect(
              Uri.parse('../live/list.m3u8?session=fixture'),
            );
          case '/live/list.m3u8':
            response.write(
              '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="keys/key.bin"\n#EXTINF:5,\nsegment.ts\n',
            );
            await response.close();
          case '/live/keys/key.bin':
            response.add(List.filled(16, 7));
            await response.close();
          case '/live/segment.ts':
            response.add([0x47, 1, 2]);
            await response.close();
          default:
            response.statusCode = 404;
            await response.close();
        }
      });
      try {
        final requested = Uri.parse(
          'http://127.0.0.1:${server.port}/entry/start.m3u8',
        );
        final response = await (await client.getUrl(requested)).close();
        final base = hlsResponseBase(requested, response);
        final body = await utf8.decoder.bind(response).join();
        final rewritten = rewriteBufferedHls(
          body,
          base,
          (uri) => uri.toString(),
        );
        final key = Uri.parse(
          RegExp('URI="([^"]+)"').firstMatch(rewritten)![1]!,
        );
        final segment = Uri.parse(
          rewritten.split('\n').firstWhere((line) => line.startsWith('http')),
        );
        expect(base.path, '/live/list.m3u8');
        for (final resource in [key, segment]) {
          final fetched = await (await client.getUrl(resource)).close();
          expect(fetched.statusCode, 200);
          expect(
            await fetched.fold<int>(
              0,
              (length, bytes) => length + bytes.length,
            ),
            greaterThan(0),
          );
        }
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    },
  );
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
