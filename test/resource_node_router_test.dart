import 'dart:io';
import 'package:clubtivi/core/resource_node_router.dart';
import 'package:clubtivi/core/resource_routing_http_client.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeHttp extends Fake implements HttpClient {
  final requests = <Uri>[];
  bool failRelay = false;
  int relayStatus = 200;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) async {
    requests.add(uri);
    if (failRelay && uri.host == 'cndrp.com') {
      throw const SocketException('offline');
    }
    return FakeRequest(
      method,
      uri,
      uri.host == 'cndrp.com' ? relayStatus : 200,
    );
  }
}

class FakeRequest extends Fake implements HttpClientRequest {
  FakeRequest(this.method, this.uri, this.status);
  final int status;
  @override
  final String method;
  @override
  final Uri uri;
  @override
  bool followRedirects = false;
  @override
  int maxRedirects = 5;
  @override
  final HttpHeaders headers = FakeHeaders();
  @override
  void add(List<int> value) {}
  @override
  Future<HttpClientResponse> close() async => FakeResponse(status);
}

class FakeHeaders extends Fake implements HttpHeaders {
  @override
  void forEach(void Function(String, List<String>) callback) {}
}

class FakeResponse extends Fake implements HttpClientResponse {
  FakeResponse(this.statusCode);
  @override
  final int statusCode;
  @override
  Future<E> drain<E>([E? futureValue]) => Future<E>.value(futureValue);
}

void main() {
  final source = Uri.parse(
    'https://bobtv.briconbric.com/api/v1/channel-catalog/events?a=1',
  );
  test(
    'chooses faster relay and preserves paths, query and canonical identity',
    () async {
      final router = ResourceNodeRouter(
        probe: (base) async =>
            Duration(milliseconds: base == ResourceNodeRouter.relay ? 15 : 80),
      );
      final result = await router.resolve(source);
      expect(
        result.toString(),
        'https://cndrp.com/bobtv/api/v1/channel-catalog/events?a=1',
      );
      expect(ResourceNodeRouter.canonical(result), source);
      expect(source.host, 'bobtv.briconbric.com');
    },
  );
  test('primary remains selected when faster or relay unavailable', () async {
    for (final relayTime in [const Duration(milliseconds: 100), null]) {
      final router = ResourceNodeRouter(
        probe: (base) async => base == ResourceNodeRouter.primary
            ? const Duration(milliseconds: 10)
            : relayTime,
      );
      expect(await router.resolve(source), source);
    }
  });
  test('concurrent requests share one probe pair and cache decision', () async {
    var count = 0;
    final router = ResourceNodeRouter(
      probe: (_) async {
        count++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return const Duration(milliseconds: 20);
      },
    );
    await Future.wait(List.generate(20, (_) => router.resolve(source)));
    await router.resolve(source);
    expect(count, 2);
  });
  test('decision expires and adapts after network changes', () async {
    var now = DateTime(2026, 10, 12), fasterRelay = true;
    final router = ResourceNodeRouter(
      now: () => now,
      probe: (base) async => Duration(
        milliseconds: (base == ResourceNodeRouter.relay) == fasterRelay
            ? 10
            : 100,
      ),
    );
    expect((await router.resolve(source)).host, 'cndrp.com');
    now = now.add(const Duration(minutes: 11));
    fasterRelay = false;
    expect(await router.resolve(source), source);
  });
  test('connect failure falls back before an upload body is sent', () async {
    final router = ResourceNodeRouter(
      probe: (base) async =>
          Duration(milliseconds: base == ResourceNodeRouter.relay ? 10 : 20),
    );
    final fake = FakeHttp()..failRelay = true;
    await ResourceRoutingHttpClient(fake, router).postUrl(source);
    expect(fake.requests.map((e) => e.host), [
      'cndrp.com',
      'bobtv.briconbric.com',
    ]);
    expect((await router.resolve(source)).host, 'bobtv.briconbric.com');
  });
  test('media never probes or selects a resource node', () async {
    final router = ResourceNodeRouter(
      probe: (_) async => throw StateError('must not probe'),
    );
    final media = Uri.parse('https://media.example.org/live.m3u8');
    final gateway = Uri.parse(
      'https://bobtv.briconbric.com/api/v1/egress/resource?kind=media&url=x',
    );
    expect(await router.resolve(media), media);
    expect(await router.resolve(gateway), gateway);
    expect(
      ResourceNodeRouter.isNode(Uri.parse('https://cndrp.com/mail/')),
      false,
    );
    expect(
      ResourceNodeRouter.isNode(
        Uri.parse('http://cndrp.com/bobtv/api/v1/sources'),
      ),
      false,
    );
  });
  test(
    'HTTP 503 read falls back once; sent uploads are not replayed',
    () async {
      for (final method in ['GET', 'POST']) {
        final router = ResourceNodeRouter(
          probe: (base) async => Duration(
            milliseconds: base == ResourceNodeRouter.relay ? 10 : 20,
          ),
        );
        final fake = FakeHttp()..relayStatus = 503;
        final request = await ResourceRoutingHttpClient(
          fake,
          router,
        ).openUrl(method, source);
        if (method == 'POST') request.add([1, 2, 3]);
        final response = await request.close();
        expect(response.statusCode, method == 'GET' ? 200 : 503);
        expect(fake.requests.length, method == 'GET' ? 2 : 1);
        expect((await router.resolve(source)).host, 'bobtv.briconbric.com');
      }
    },
  );
}
