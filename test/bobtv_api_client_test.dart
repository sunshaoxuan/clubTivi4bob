import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late BobTvApiClient client;
  final requests = <Map<String, Object?>>[];
  var catalogStatus = 200;
  var catalogBody = '{"sources":[]}';
  var reportStatus = 202;

  setUp(() async {
    requests.clear();
    catalogStatus = 200;
    catalogBody = '{"sources":[]}';
    reportStatus = 202;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      requests.add({
        'path': request.uri.path,
        'method': request.method,
        'body': body,
        'type': request.headers.contentType?.mimeType,
      });
      if (request.uri.path == '/api/v1/sources') {
        request.response.statusCode = catalogStatus;
        request.response.write(catalogBody);
      } else if (request.uri.path == '/api/v1/source-reports') {
        request.response.statusCode = reportStatus;
        request.response.write('{"accepted":true}');
      } else if (request.uri.path == '/api/v1/source-candidates') {
        request.response.statusCode = 202;
        request.response.write('{"id":"ca0e7bd553f2","pendingReview":true}');
      } else if (request.uri.path == '/api/v1/logs') {
        request.response.statusCode = 201;
        request.response.write(
          '{"id":"${'a' * 64}","duplicate":false}',
        );
      } else if (request.uri.path == '/releases.json') {
        request.response.statusCode = 200;
        request.response.write(jsonEncode({
          'releases': [{
            'version': 'v0.9.1-bob.9',
            'date': '2026-09-27',
            'filename': 'BobTV-v0.9.1-bob.9-windows-x64.zip',
            'size': '62.0 MB',
            'sha256': 'a' * 64,
          }],
        }));
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    client = BobTvApiClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
    );
  });

  tearDown(() async {
    client.close();
    await server.close(force: true);
  });

  test('empty reviewed catalog is a successful result', () async {
    expect(await client.fetchSources(), isEmpty);
    expect(requests.single['path'], '/api/v1/sources');
  });

  test('rejects invalid catalog without publishing partial entries', () async {
    catalogBody = jsonEncode({
      'sources': [
        {'id': 'valid', 'name': 'Test', 'url': 'https://media.example.com/a.m3u8'},
        {'id': 'Invalid ID', 'name': 'Bad', 'url': 'https://media.example.com/b'},
      ],
    });
    await expectLater(client.fetchSources(), throwsFormatException);
  });

  test('reports only exact allowed fields with 64-character fingerprint', () async {
    await client.postPlaybackReport(
      sourceId: 'reviewed-1', fingerprint: 'a' * 64, playable: true,
    );
    expect(requests.single['path'], '/api/v1/source-reports');
    expect(jsonDecode(requests.single['body'] as String), {
      'sourceId': 'reviewed-1',
      'fingerprint': 'a' * 64,
      'playable': true,
    });
    expect(requests.single['type'], 'application/json');
    await expectLater(client.postPlaybackReport(
      sourceId: 'reviewed-1', fingerprint: 'bad', playable: true,
    ), throwsFormatException);
    expect(requests.length, 1);
  });

  test('candidate requires consent and public HTTPS URL', () async {
    for (final invalid in [
      'http://media.example.com/live.m3u8',
      'https://localhost/live.m3u8',
      'https://192.0.2.1/live.m3u8',
      'https://media.example.com:8443/live.m3u8',
      'https://media.example.com/live.m3u8?token=secret',
    ]) {
      expect(BobTvApiClient.isSafeMediaUrl(invalid, candidate: true), isFalse);
    }
    await expectLater(client.submitCandidate(
      name: 'Test', url: 'https://media.example.com/live.m3u8',
      device: 'Windows', fingerprint: 'b' * 64, consent: false,
    ), throwsFormatException);
    expect(requests, isEmpty);
    final receipt = await client.submitCandidate(
      name: 'Test', url: 'https://media.example.com/live.m3u8',
      device: 'Windows', fingerprint: 'b' * 64, consent: true,
    );
    expect(receipt, 'ca0e7bd553f2');
    expect((jsonDecode(requests.single['body'] as String) as Map).keys.toSet(),
      {'name', 'url', 'device', 'fingerprint', 'consent'});
  });

  test('uploads NDJSON and accepts 201 receipt', () async {
    final payload = utf8.encode(
      '{"time":"2026-09-27T00:00:00Z","event":"startup"}\n',
    );
    expect(await client.uploadLogSnapshot(payload), isFalse);
    expect(requests.single['type'], 'application/x-ndjson');
  });

  test('reads release metadata without inferring an installation', () async {
    final releases = await client.fetchReleases();
    expect(releases.single.version, 'v0.9.1-bob.9');
    expect(releases.single.filename,
        'BobTV-v0.9.1-bob.9-windows-x64.zip');
    expect(requests.single['path'], '/releases.json');
  });

  test('surfaces a validation status without repeating a report', () async {
    reportStatus = 422;
    await expectLater(client.postPlaybackReport(
      sourceId: 'reviewed-1', fingerprint: 'a' * 64, playable: false,
    ), throwsA(isA<BobTvApiException>().having(
      (error) => error.statusCode, 'statusCode', 422,
    )));
    expect(requests.length, 1);
  });
}
