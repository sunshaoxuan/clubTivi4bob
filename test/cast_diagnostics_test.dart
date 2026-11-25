import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/diagnostic_sync_service.dart';
import 'package:clubtivi/core/app_diagnostics.dart';
import 'package:clubtivi/features/casting/cast_diagnostics.dart';
import 'package:clubtivi/features/casting/lan_cast_relay.dart';

class RecordingApi extends BobTvApiClient {
  static bool failUpload = false;
  static final uploads = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> uploadDiagnosticBatch(
    List<int> body, {
    Uri? node,
  }) async {
    uploads.add(jsonDecode(utf8.decode(body)) as Map<String, dynamic>);
    if (failUpload) {
      throw BobTvApiException(
        'diagnostics_upload',
        statusCode: 429,
        retryAfter: const Duration(minutes: 5),
      );
    }
    return {'state': 'origin_accepted'};
  }
}

Future<void> waitFor(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for diagnostic upload');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cast HTTP trace survives projection without URL, payload or device name',
    () async {
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
      final folder = await Directory.systemTemp.createTemp('cast-log-test-');
      final diagnostics = AppDiagnostics.instance;
      await diagnostics.initialize(directoryOverride: folder);
      final cast = CastDiagnostics.instance;
      cast.begin();
      cast.target(
        'dlna',
        'Private living room 192.168.2.1',
        'https://example.test/private.m3u8?token=secret',
      );
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        request.response.statusCode = 403;
        request.response.write('private-video-content');
        await request.response.close();
      });
      final relay = LanCastRelay();
      final address = await relay.start(
        Uri.parse('http://127.0.0.1:${upstream.port}/secret.ts'),
        '127.0.0.1',
        upstream.port,
        localAddress: InternetAddress.loopbackIPv4,
      );
      final client = HttpClient();
      final response = await (await client.getUrl(Uri.parse(address))).close();
      expect(response.statusCode, 403);
      await response.drain<void>();
      await relay.close();
      await upstream.close(force: true);
      client.close(force: true);
      await diagnostics.flush();
      final chunk = await diagnostics.safeStore!.readChunk({});
      final events = chunk.entries
          .where((e) => (e['event'] as String).startsWith('cast_'))
          .toList();
      expect(
        events.any(
          (e) =>
              e['event'] == 'cast_relay_upstream_headers' &&
              e['httpStatus'] == 403,
        ),
        isTrue,
      );
      expect(events.any((e) => e['event'] == 'cast_relay_first_byte'), isTrue);
      expect(events.map((e) => e['requestId']).toSet().length, 1);
      final encoded = jsonEncode(events);
      for (final secret in [
        'secret',
        'example.test',
        'private-video-content',
        '192.168',
        'living room',
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
      cast.begin();
      cast.record('new_session');
      await diagnostics.flush();
      final next = await diagnostics.safeStore!.readChunk({});
      final last = next.entries.last;
      expect(last['requestId'], isNot(events.first['requestId']));
      expect(last.containsKey('castStreamId'), isFalse);
      final sync = DiagnosticSyncService(
        observeLifecycle: false,
        apiFactory: RecordingApi.new,
        fingerprintResolver: () async => 'ab' * 32,
        countryResolver: (_) async => 'CN',
        castUploadDelay: const Duration(milliseconds: 30),
      );
      await sync.start();
      expect(sync.enabled, isFalse);
      expect(RecordingApi.uploads, isEmpty);
      await sync.setEnabled(true);
      await waitFor(() => sync.status.value.contains('已同步'));
      expect(RecordingApi.uploads.last['terminalFingerprint'], 'ab' * 32);
      final before = RecordingApi.uploads.length;
      cast.record('upload_trigger');
      await diagnostics.flush();
      await waitFor(() => RecordingApi.uploads.length > before);
      expect(
        RecordingApi.uploads.last['entries'],
        contains(predicate((dynamic e) => e['event'] == 'cast_upload_trigger')),
      );
      await sync.setEnabled(false);
      final disabledCount = RecordingApi.uploads.length;
      cast.record('disabled_upload');
      await diagnostics.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(RecordingApi.uploads.length, disabledCount);
      RecordingApi.failUpload = true;
      await sync.setEnabled(true);
      await waitFor(() => sync.status.value.contains('待重试'));
      final failedCount = RecordingApi.uploads.length;
      cast.record('backoff_preserved');
      await diagnostics.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(RecordingApi.uploads.length, failedCount);
      sync.dispose();
      await diagnostics.shutdown();
      await folder.delete(recursive: true);
    },
  );
}
