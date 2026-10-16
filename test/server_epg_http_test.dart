import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'version requests bypass cache and immutable downloads verify SHA-256',
    () async {
      final bytes = gzip.encode(utf8.encode('synthetic transport fixture'));
      final hash = sha256.convert(bytes).toString();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final api = BobTvApiClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      addTearDown(() async {
        api.close();
        await server.close(force: true);
      });
      String? cache, pragma;
      var damaged = false;
      server.listen((request) async {
        if (request.uri.path == '/api/v1/epg/manifest') {
          cache = request.headers.value('cache-control');
          pragma = request.headers.value('pragma');
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'schemaVersion': 1,
              'version': 'epg-${'a' * 64}',
              'sha256': hash,
              'snapshotUrl': '/api/v1/epg/snapshots/$hash.json.gz',
              'compressedBytes': bytes.length,
              'channelCount': 1,
              'programmeCount': 2,
              'generatedAt': '2026-10-16T06:00:00Z',
              'coverageStartUtc': 1792130000,
              'coverageEndUtc': 1792140000,
            }),
          );
        } else {
          request.response.add(damaged ? [1, 2, 3] : bytes);
        }
        await request.response.close();
      });
      final manifest = (await api.fetchEpgManifest())!;
      expect(cache, contains('no-cache'));
      expect(cache, contains('no-store'));
      expect(pragma, 'no-cache');
      expect(await api.downloadEpgSnapshot(manifest), bytes);
      damaged = true;
      await expectLater(
        api.downloadEpgSnapshot(manifest),
        throwsFormatException,
      );
    },
  );

  test(
    'version endpoint rejects redirects and preserves upstream Retry-After',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final api = BobTvApiClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      addTearDown(() async {
        api.close();
        await server.close(force: true);
      });
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.statusCode = requests == 1 ? 302 : 429;
        request.response.headers.set(
          'location',
          'https://example.org/not-allowed',
        );
        request.response.headers.set('retry-after', '120');
        await request.response.close();
      });
      await expectLater(
        api.fetchEpgManifest(),
        throwsA(
          isA<BobTvApiException>().having((e) => e.statusCode, 'status', 302),
        ),
      );
      expect(requests, 1);
      await expectLater(
        api.fetchEpgManifest(),
        throwsA(
          isA<BobTvApiException>()
              .having((e) => e.statusCode, 'status', 429)
              .having(
                (e) => e.retryAfter,
                'retry',
                const Duration(seconds: 120),
              ),
        ),
      );
      expect(requests, 2);
    },
  );
}
