import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/features/player/hls_playlist_transport.dart';

void main() {
  test(
    'live refresh stays on one CDN session and renews an expired session',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      final transport = HlsPlaylistTransport();
      var entries = 0;
      var expired = false;
      server.listen((request) async {
        final response = request.response;
        if (request.uri.path == '/entry') {
          entries++;
          await response.redirect(Uri.parse('/session-$entries/list.m3u8'));
        } else if (request.uri.path == '/session-1/list.m3u8' && expired) {
          response.statusCode = 403;
          await response.close();
        } else {
          response.write('#EXTM3U\n#EXTINF:10,\n${request.uri.path}.ts\n');
          await response.close();
        }
      });
      try {
        final entry = Uri.parse('http://127.0.0.1:${server.port}/entry');
        final first = await transport.read(client, entry, {});
        expect(first.origin.path, '/session-1/list.m3u8');
        for (var i = 0; i < 3; i++) {
          expect(
            (await transport.read(client, entry, {})).origin,
            first.origin,
          );
        }
        expect(entries, 1);
        expired = true;
        expect(
          (await transport.read(client, entry, {})).origin.path,
          '/session-2/list.m3u8',
        );
        expect(entries, 2);
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    },
  );

  test(
    'cached redirects do not forward credentials to a different host',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      final transport = HlsPlaylistTransport();
      final seen = <String?>[];
      server.listen((request) async {
        if (request.uri.path == '/entry') {
          await request.response.redirect(
            Uri.parse('http://localhost:${server.port}/list.m3u8'),
          );
        } else {
          seen.add(request.headers.value('authorization'));
          request.response.write('#EXTM3U\n');
          await request.response.close();
        }
      });
      try {
        final source = Uri.parse('http://127.0.0.1:${server.port}/entry');
        for (var i = 0; i < 2; i++) {
          await transport.read(client, source, {
            'Authorization': 'Bearer test-only',
          });
        }
        expect(seen, [null, null]);
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    },
  );

  test('stopped sessions cannot restore a late redirect target', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = HttpClient();
    final transport = HlsPlaylistTransport();
    final entered = Completer<void>(), release = Completer<void>();
    var entries = 0;
    server.listen((request) async {
      if (request.uri.path == '/entry') {
        entries++;
        await request.response.redirect(
          Uri.parse('/session-$entries/list.m3u8'),
        );
      } else {
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
        request.response.write('#EXTM3U\n');
        await request.response.close();
      }
    });
    try {
      final source = Uri.parse('http://127.0.0.1:${server.port}/entry');
      final pending = transport.read(client, source, {});
      await entered.future;
      transport.clear();
      release.complete();
      await pending;
      expect(
        (await transport.read(client, source, {})).origin.path,
        '/session-2/list.m3u8',
      );
      expect(entries, 2);
      await expectLater(
        transport.read(client, source, {}, maxBytes: 1),
        throwsFormatException,
      );
    } finally {
      client.close(force: true);
      await server.close(force: true);
    }
  });
}
