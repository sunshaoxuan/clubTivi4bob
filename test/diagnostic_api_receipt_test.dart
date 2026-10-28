import 'dart:convert';
import 'dart:io';
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late BobTvApiClient api;
  var cache = 'private, no-store';
  var wrongId = false;
  var state = 'origin_accepted';
  var writes = 0;
  setUp(() async {
    cache = 'private, no-store';
    wrongId = false;
    state = 'origin_accepted';
    writes = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await request.fold<List<int>>(
        [],
        (value, part) => value..addAll(part),
      );
      writes++;
      request.response.statusCode = 201;
      request.response.headers.set('Cache-Control', cache);
      request.response.write(
        jsonEncode({
          'id': wrongId ? '0' * 64 : sha256.convert(body).toString(),
          'state': state,
        }),
      );
      await request.response.close();
    });
    api = BobTvApiClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      recordDiagnostics: false,
    );
  });
  tearDown(() async {
    api.close();
    await server.close(force: true);
  });
  test(
    'origin and relay receipts require exact hash and known state',
    () async {
      final body = utf8.encode('{"fixture":"safe"}');
      expect(
        (await api.uploadDiagnosticBatch(body))['state'],
        'origin_accepted',
      );
      state = 'relay_stored';
      expect((await api.uploadDiagnosticBatch(body))['state'], 'relay_stored');
      wrongId = true;
      await expectLater(api.uploadDiagnosticBatch(body), throwsFormatException);
      wrongId = false;
      state = 'invented_success';
      await expectLater(api.uploadDiagnosticBatch(body), throwsFormatException);
      expect(writes, 4);
    },
  );
  test('shared cached acknowledgments never commit upload success', () async {
    cache = 'public, max-age=3600';
    await expectLater(api.uploadDiagnosticBatch([1, 2]), throwsFormatException);
    expect(writes, 1);
  });
}
