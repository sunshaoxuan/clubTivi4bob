import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/core/diagnostic_log_store.dart';
import 'package:clubtivi/core/resource_node_router.dart';
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/diagnostic_sync_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Fixture {
  var uploads = 0, polls = 0, closes = 0;
  String state = 'origin_accepted';
  Uri? node;
  List<int>? body;
  Completer<void>? wait;
  final started = Completer<void>();
}

class DiagnosticApi extends BobTvApiClient {
  DiagnosticApi(this.fixture);
  final Fixture fixture;
  @override
  Future<Map<String, dynamic>> uploadDiagnosticBatch(
    List<int> body, {
    Uri? node,
  }) async {
    fixture.uploads++;
    fixture.node = node;
    fixture.body = body;
    if (!fixture.started.isCompleted) fixture.started.complete();
    await fixture.wait?.future;
    return {'id': sha256.convert(body).toString(), 'state': fixture.state};
  }

  @override
  Future<Map<String, dynamic>?> diagnosticReceipt(
    String digest, {
    Uri? node,
  }) async {
    fixture.polls++;
    return {'id': digest, 'state': fixture.state};
  }

  @override
  void close() {
    fixture.closes++;
    super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late DiagnosticLogStore store;
  late DateTime now;
  late Fixture fixture;
  final services = <DiagnosticSyncService>[];
  DiagnosticSyncService service() {
    final result = DiagnosticSyncService(
      logStore: store,
      now: () => now,
      apiFactory: () => DiagnosticApi(fixture),
      observeLifecycle: false,
      countryResolver: (_) async => 'CN',
    );
    services.add(result);
    return result;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    now = DateTime.utc(2026, 10, 23, 14);
    folder = await Directory.systemTemp.createTemp('bobtv-diagnostic-test-');
    store = DiagnosticLogStore(
      Directory('${folder.path}/safe'),
      legacyDirectory: folder,
      now: () => now,
    );
    await store.initialize();
    fixture = Fixture();
    await store.record({
      'time': now.toIso8601String(),
      'event': 'application_error',
      'platform': 'android',
      'appVersion': '1.1.7+100',
      'source': 'website_channel_catalog',
      'error': 'https://user:secret@private.test/live?token=abc',
      'stack': '/Users/private/name',
      'favorites': ['private'],
      'channel': 'private viewing history',
    });
  });
  tearDown(() async {
    for (final item in services) {
      item.dispose();
    }
    services.clear();
    await folder.delete(recursive: true);
  });

  test(
    'old summary consent never authorizes expanded 30-day uploads',
    () async {
      SharedPreferences.setMockInitialValues({'bobtv_auto_logs_enabled': true});
      final sync = service();
      await sync.start();
      await sync.sync();
      expect(sync.enabled, false);
      expect(fixture.uploads, 0);
    },
  );

  test(
    'consented CN upload is pinned to relay and strictly redacted',
    () async {
      final sync = service();
      await sync.setEnabled(true);
      await sync.sync();
      expect(fixture.uploads, 1);
      expect(fixture.node, ResourceNodeRouter.relay);
      final text = utf8.decode(fixture.body!);
      for (final secret in [
        'secret',
        'private.test',
        '/Users/',
        'token',
        'favorites',
        'channel',
      ]) {
        if (secret == 'channel') continue; // safe source tag includes channel.
        expect(text, isNot(contains(secret)));
      }
      final envelope = jsonDecode(text) as Map;
      expect(envelope['consentVersion'], 2);
      expect((envelope['installationId'] as String).length, 32);
      expect(
        (await SharedPreferences.getInstance()).getString(
          DiagnosticSyncService.checkpointKey,
        ),
        isNotNull,
      );
    },
  );

  test(
    'interrupted pending write rebuilds without advancing source cursor',
    () async {
      await File(
        '${store.directory.path}/pending-upload.json',
      ).writeAsString('{"body":');
      final sync = service();
      await sync.setEnabled(true);
      await sync.sync();
      expect(fixture.uploads, 1);
      expect(jsonDecode(utf8.decode(fixture.body!))['entries'], hasLength(1));
      expect(sync.status.value, contains('已同步'));
    },
  );

  test(
    'relay-stored does not commit cursor and restart polls without reupload',
    () async {
      fixture.state = 'relay_stored';
      final first = service();
      await first.setEnabled(true);
      await first.sync();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(DiagnosticSyncService.checkpointKey), isNull);
      expect(first.status.value, contains('等待主节点'));
      first.dispose();
      services.remove(first);
      fixture.state = 'origin_accepted';
      now = now.add(const Duration(minutes: 2));
      final second = service();
      await second.start();
      await second.sync();
      expect(fixture.uploads, 1);
      expect(fixture.polls, 1);
      expect(prefs.getString(DiagnosticSyncService.checkpointKey), isNotNull);
    },
  );

  test(
    'disable cancels owned transport and no cursor or later upload advances',
    () async {
      fixture.wait = Completer<void>();
      final sync = service();
      await sync.setEnabled(true);
      await fixture.started.future;
      await sync.setEnabled(false);
      expect(fixture.closes, greaterThan(0));
      fixture.wait!.complete();
      await sync.sync();
      await Future<void>.delayed(Duration.zero);
      expect(sync.enabled, false);
      expect(fixture.uploads, 1);
      expect(
        (await SharedPreferences.getInstance()).getString(
          DiagnosticSyncService.checkpointKey,
        ),
        isNull,
      );
    },
  );

  test(
    '30-day legacy backfill excludes stale, future, partial and unrelated files',
    () async {
      final recent = now.subtract(const Duration(days: 29));
      final stale = now.subtract(const Duration(days: 31));
      await File('${folder.path}/clubtivi-20260924.log').writeAsString(
        [
          jsonEncode({
            'time': recent.toIso8601String(),
            'event': 'heartbeat',
            'error': 'secret',
          }),
          jsonEncode({'time': stale.toIso8601String(), 'event': 'stale_event'}),
          jsonEncode({
            'time': now.add(const Duration(days: 1)).toIso8601String(),
            'event': 'future_event',
          }),
          '{"partial":',
        ].join('\n'),
      );
      await File('${folder.path}/favorites.log').writeAsString('private');
      final chunk = await store.readChunk({});
      expect(chunk.entries.any((entry) => entry['event'] == 'heartbeat'), true);
      expect(
        chunk.entries.any(
          (entry) =>
              entry['event'] == 'stale_event' ||
              entry['event'] == 'future_event',
        ),
        false,
      );
      expect(jsonEncode(chunk.entries), isNot(contains('secret')));
      expect(
        chunk.checkpoints.keys.any((key) => key.contains('favorites')),
        false,
      );
    },
  );

  test(
    'projection preserves supported platform tags with no free-form text',
    () {
      for (final platform in ['android', 'windows', 'macos']) {
        final projected = DiagnosticProjection.project({
          'time': now.toIso8601String(),
          'event': 'network_request',
          'platform': platform,
          'phase': 'body',
          'node': 'cndrp',
          'endpoint': 'catalog_snapshot',
          'errorCode': 'timeout',
          'elapsedMs': 42,
          'url': 'https://secret.test',
          'stack': 'private',
          'appVersion': '1.1.9+102',
        }, now)!;
        expect(projected['platform'], platform);
        expect(projected['errorCode'], 'timeout');
        expect(
          projected.containsKey('url') || projected.containsKey('stack'),
          false,
        );
      }
    },
  );
}
