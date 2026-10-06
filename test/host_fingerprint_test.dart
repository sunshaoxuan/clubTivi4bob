import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/services/host_fingerprint_service.dart';
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const uuid = '12345678-1234-5678-9abc-123456789abc';
  test('hardware command output is parsed without installation data', () {
    expect(HostFingerprintService.parseUuid('windows', ' $uuid\r\n'), uuid);
    expect(
      HostFingerprintService.parseUuid('macos', '"IOPlatformUUID" = "$uuid"'),
      uuid,
    );
    expect(HostFingerprintService.parseUuid('macos', 'no UUID'), isNull);
  });
  test('identity survives fresh installations and normalized UUID casing', () {
    final first = HostFingerprintService.derive('windows', uuid);
    expect(first, matches(RegExp(r'^bth1_[a-f0-9]{64}$')));
    for (var i = 0; i < 20; i++) {
      expect(
        HostFingerprintService.derive('windows', ' ${uuid.toUpperCase()} \n'),
        first,
      );
    }
    expect(
      HostFingerprintService.derive(
        'windows',
        '22345678-1234-5678-9abc-123456789abc',
      ),
      isNot(first),
    );
    expect(HostFingerprintService.derive('macos', uuid), first);
  });
  test('invalid hardware never becomes a random host', () {
    for (final value in [
      '',
      'unknown',
      '0' * 32,
      '00000000-0000-0000-0000-000000000000',
      '03000200-0400-0500-0006-000700080009',
      'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF',
    ]) {
      expect(HostFingerprintService.derive('windows', value), isNull);
    }
    expect(HostFingerprintService.derive('linux', uuid), isNull);
  });
  test(
    'registration sends hash only, retries are bounded, repeat registration is identical',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bodies = <Map<String, dynamic>>[];
      var status = 503;
      server.listen((request) async {
        expect(request.uri.path, '/api/v1/devices/register');
        bodies.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        request.response.statusCode = status;
        request.response.write('{"registered":true}');
        await request.response.close();
      });
      final api = BobTvApiClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      addTearDown(() async {
        api.close();
        await server.close(force: true);
      });
      Future<void> register(String? value) => HostFingerprintService.register(
        platform: 'windows',
        readUuid: (_) async => value,
        api: api,
        delay: (_) async {},
      );
      await register(uuid);
      expect(bodies.length, 3);
      status = 200;
      await register(uuid);
      expect(bodies.length, 4);
      for (final body in bodies) {
        expect(body, {
          'hostFingerprint': HostFingerprintService.derive('windows', uuid),
        });
        expect(jsonEncode(body), isNot(contains(uuid)));
      }
      await register(null);
      await register('unknown');
      expect(bodies.length, 4);
      status = 429;
      await register(uuid);
      expect(bodies.length, 5);
      await expectLater(api.registerHost(uuid), throwsFormatException);
      expect(bodies.length, 5);
      await HostFingerprintService.register(
        platform: 'windows',
        readUuid: (_) async => throw const FileSystemException('unavailable'),
        api: api,
      );
      expect(bodies.length, 5);
    },
  );
  test(
    'real Windows reader registers the same host on repeated fresh reads',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bodies = <String>[];
      server.listen((request) async {
        bodies.add(await utf8.decoder.bind(request).join());
        request.response.write('{"registered":true}');
        await request.response.close();
      });
      final api = BobTvApiClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      addTearDown(() async {
        api.close();
        await server.close(force: true);
      });
      await HostFingerprintService.register(api: api);
      await HostFingerprintService.register(api: api);
      expect(bodies.length, 2);
      expect(bodies[0] == bodies[1], isTrue);
      expect((jsonDecode(bodies[0]) as Map).keys.toList(), ['hostFingerprint']);
    },
    skip: !Platform.isWindows,
  );
}
