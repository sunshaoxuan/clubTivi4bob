import 'dart:async';
import 'dart:io';

import 'package:clubtivi/core/resource_node_router.dart';
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

// These are local fixture timings, not production transport settings. Keep a
// wide gap so loopback setup under a busy build cannot mimic the failed node.
const fixtureTimeout = Duration(milliseconds: 250);
const fixtureFaultDelay = Duration(seconds: 1);

class MappedHttp extends Fake implements HttpClient {
  MappedHttp(this.relayPort, this.originPort);
  final int relayPort, originPort;
  final actual = HttpClient();
  final attempts = <String>[];
  bool delayOpen = false;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) async {
    attempts.add(uri.host);
    if (delayOpen && uri.host == 'cndrp.com') {
      await Future<void>.delayed(fixtureFaultDelay);
    }
    return actual.openUrl(
      method,
      Uri.parse(
        'http://127.0.0.1:${uri.host == 'cndrp.com' ? relayPort : originPort}${uri.path}',
      ),
    );
  }

  @override
  void close({bool force = false}) => actual.close(force: force);
}

void main() {
  late HttpServer relay, origin;
  late MappedHttp http;
  late BobTvApiClient api;
  var fault = '';
  var originWrites = 0, relayWrites = 0;
  setUp(() async {
    fault = '';
    originWrites = relayWrites = 0;
    relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Future<void> respond(HttpRequest req, bool isRelay) async {
      try {
        await req.drain<void>();
        if (req.method == 'POST') {
          if (isRelay) {
            relayWrites++;
          } else {
            originWrites++;
          }
        }
        if (isRelay && fault == 'headers') {
          await Future<void>.delayed(fixtureFaultDelay);
        }
        if (isRelay && fault == 'busy') {
          req.response.statusCode = 503;
          req.response.headers.set('Retry-After', '60');
          req.response.write('{"detail":"Channel state temporarily busy"}');
        } else if (isRelay && fault == 'body') {
          req.response.write('{"sources":');
          await req.response.flush();
          await Future<void>.delayed(fixtureFaultDelay);
          req.response.write('[]}');
        } else {
          req.response.write('{"sources":[]}');
        }
        await req.response.close();
      } catch (_) {
        /* Aborted fixture connections are expected. */
      }
    }

    relay.listen((req) => unawaited(respond(req, true)));
    origin.listen((req) => unawaited(respond(req, false)));
    http = MappedHttp(relay.port, origin.port);
    final router = ResourceNodeRouter(
      probe: (node) async =>
          Duration(milliseconds: node == ResourceNodeRouter.relay ? 1 : 2),
    );
    api = BobTvApiClient(
      httpClient: http,
      router: router,
      openTimeout: fixtureTimeout,
      headerTimeout: fixtureTimeout,
      bodyTimeout: fixtureTimeout,
    );
  });
  tearDown(() async {
    api.close();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await relay.close(force: true);
    await origin.close(force: true);
  });
  for (final stage in ['open', 'headers', 'body']) {
    test(
      '$stage timeout retries whole GET at the alternate node once',
      () async {
        fault = stage;
        http.delayOpen = stage == 'open';
        expect(await api.fetchSources(), isEmpty);
        expect(http.attempts, ['cndrp.com', 'bobtv.briconbric.com']);
        expect(api.nodeRouter!.selected, ResourceNodeRouter.primary);
      },
    );
  }
  test('POST after sending body is never replayed on timeout', () async {
    fault = 'headers';
    await expectLater(
      api.postPlaybackReport(
        sourceId: 'fixture',
        fingerprint: 'a' * 64,
        playable: true,
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(relayWrites, 1);
    expect(originWrites, 0);
    expect(http.attempts, ['cndrp.com']);
  });
  test(
    'origin backpressure respects Retry-After without node thrashing',
    () async {
      fault = 'busy';
      await expectLater(
        api.fetchSources(),
        throwsA(
          isA<BobTvApiException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 60),
          ),
        ),
      );
      expect(http.attempts, ['cndrp.com']);
      expect(api.nodeRouter!.selected, ResourceNodeRouter.relay);
    },
  );
}
