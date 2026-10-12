import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/models/device_favorites_snapshot.dart';
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/device_favorites_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late BobTvApiClient api;
  final requests = <Map<String, Object?>>[];
  var status = 200;
  var oversized = false;
  var privateHeaders = true;
  final credential = DeviceFavoritesCredential(
    fingerprint: 'a' * 64,
    token: 'btvf1_${'b' * 64}',
  );
  setUp(() async {
    requests.clear();
    status = 200;
    oversized = false;
    privateHeaders = true;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add({
        'path': request.uri.path,
        'query': request.uri.query,
        'auth': request.headers.value('authorization'),
        'fingerprint': request.headers.value('x-bobtv-device-fingerprint'),
        'etag': request.headers.value('if-none-match'),
        'body': await utf8.decoder.bind(request).join(),
      });
      request.response.statusCode = status;
      if (privateHeaders) {
        request.response.headers.set('Cache-Control', 'private, no-store');
        request.response.headers.set(
          'Vary',
          'Authorization, X-BobTV-Device-Fingerprint',
        );
      }
      if (status == 302) {
        request.response.headers.set(
          'Location',
          'https://untrusted.invalid/steal',
        );
      }
      if (status != 304) {
        request.response.write(
          oversized
              ? 'x' * (512 * 1024 + 1)
              : status == 404
              ? '{"detail":"No backup for this device"}'
              : request.method == 'GET'
              ? jsonEncode({
                  'schemaVersion': 1,
                  'revision': 1,
                  'snapshot': const DeviceFavoritesSnapshot().toJson(),
                })
              : '{"revision":1,"duplicate":false}',
        );
      }
      await request.response.close();
    });
    api = BobTvApiClient(baseUri: Uri.parse('http://127.0.0.1:${server.port}'));
  });
  tearDown(() async {
    api.close();
    await server.close(force: true);
  });

  test(
    'private GET/PUT carry credential only in headers, never a public endpoint or query',
    () async {
      final remote = await api.fetchDeviceFavorites(credential: credential);
      expect(remote!.snapshot!.isEmpty, true);
      expect(
        await api.saveDeviceFavorites(
          credential: credential,
          snapshot: const DeviceFavoritesSnapshot(),
          baseRevision: 0,
        ),
        1,
      );
      for (final request in requests) {
        expect(request['path'], '/api/v1/device-favorites');
        expect(request['query'], '');
        expect(request['auth'], 'Bearer ${credential.token}');
        expect(request['fingerprint'], credential.fingerprint);
        expect(request['body'], isNot(contains(credential.token)));
        expect(request['body'], isNot(contains(credential.fingerprint)));
      }
      expect(jsonDecode(requests.last['body'] as String), {
        'schemaVersion': 1,
        'baseRevision': 0,
        'snapshot': const DeviceFavoritesSnapshot().toJson(),
      });
    },
  );

  test(
    'missing backup, conditional unchanged, redirects and response limits are distinct',
    () async {
      status = 404;
      expect(await api.fetchDeviceFavorites(credential: credential), isNull);
      status = 304;
      final unchanged = await api.fetchDeviceFavorites(
        credential: credential,
        ifRevision: 3,
      );
      expect(unchanged!.revision, 3);
      expect(unchanged.snapshot, isNull);
      expect(requests.last['etag'], '"favorites-v1-3"');
      status = 302;
      await expectLater(
        api.fetchDeviceFavorites(credential: credential),
        throwsA(isA<BobTvApiException>()),
      );
      expect(requests, hasLength(3));
      status = 200;
      oversized = true;
      await expectLater(
        api.fetchDeviceFavorites(credential: credential),
        throwsFormatException,
      );
    },
  );

  test(
    'a cacheable favorite response is rejected before restoration',
    () async {
      privateHeaders = false;
      await expectLater(
        api.fetchDeviceFavorites(credential: credential),
        throwsA(
          isA<BobTvApiException>().having(
            (error) => error.reason,
            'reason',
            'private_favorites_cache_policy',
          ),
        ),
      );
    },
  );

  test(
    'invalid credentials and unknown origin are rejected before sending',
    () async {
      await expectLater(
        api.fetchDeviceFavorites(
          credential: DeviceFavoritesCredential(
            fingerprint: 'a' * 64,
            token: 'public-fingerprint-only',
          ),
        ),
        throwsFormatException,
      );
      final other = BobTvApiClient(
        baseUri: Uri.parse('https://other.example.org'),
      );
      await expectLater(
        other.fetchDeviceFavorites(credential: credential),
        throwsFormatException,
      );
      other.close();
      expect(requests, isEmpty);
    },
  );
}
