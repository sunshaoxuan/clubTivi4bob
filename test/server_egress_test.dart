import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clubtivi/core/server_egress.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class CaptureAdapter implements HttpClientAdapter {
  RequestOptions? last;
  String body = '';
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    last = options;
    if (requestStream != null) {
      body = utf8.decode(await requestStream.expand((part) => part).toList());
    }
    return ResponseBody.fromString(
      '{"ok":true}',
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'legacy GitHub and AI calls are blocked before credentials leave',
    () async {
      final capture = CaptureAdapter();
      final dio = Dio();
      dio.httpClientAdapter = ServerEgressAdapter(capture);
      for (final url in [
        'https://api.github.com/repos/a/b',
        'https://ccnode.briconbric.com:49531/v1/chat/completions',
      ]) {
        await expectLater(
          dio.get(
            url,
            options: Options(headers: {'Authorization': 'Bearer fake-secret'}),
          ),
          throwsA(isA<DioException>()),
        );
      }
      expect(capture.last, isNull);
      expect(capture.body, isEmpty);
      dio.close();
    },
  );
  test('all remote media becomes a server URL without changing identity', () {
    const source = 'https://raw.githubusercontent.com/a/b/live.m3u8';
    final gateway = Uri.parse(ServerEgress.mediaUrl(source));
    expect(gateway.host, 'bobtv.briconbric.com');
    expect(gateway.queryParameters['url'], source);
    expect(ServerEgress.mediaUrl(gateway.toString()), gateway.toString());
    expect(
      ServerEgress.mediaUrl('http://127.0.0.1:8080/'),
      'http://127.0.0.1:8080/',
    );
    expect(ServerEgress.mediaUrl('/tmp/recording.ts'), '/tmp/recording.ts');
    expect(ServerEgress.mediaUrl(r'C:\TV\recording.ts'), r'C:\TV\recording.ts');
    expect(
      () => ServerEgress.mediaUrl('rtsp://public.example.org/live'),
      throwsFormatException,
    );
  });

  test('image and EPG routes include only the server origin', () {
    expect(
      Uri.parse(ServerEgress.imageUrl('https://github.com/a/logo.png')).host,
      'bobtv.briconbric.com',
    );
    expect(
      ServerEgress.resourceUri(
        'https://epg.example.org/t.xml.gz',
        'epg',
      ).queryParameters['kind'],
      'epg',
    );
    expect(
      () => ServerEgress.resourceUri(
        'https://user:password@example.org/a',
        'media',
      ),
      throwsFormatException,
    );
  });

  test('required media headers are carried without unrelated secrets', () {
    final uri = ServerEgress.resourceUri(
      'https://media.example.org/a|Referer=https%3A%2F%2Ftv.example.org%2F&Authorization=secret',
      'media',
    );
    expect(jsonDecode(uri.queryParameters['headers']!), {
      'referer': 'https://tv.example.org/',
    });
  });

  test(
    'integration auth added by later interceptors is in TLS POST body',
    () async {
      final capture = CaptureAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.themoviedb.org/3'));
      dio.httpClientAdapter = ServerEgressAdapter(capture);
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            options.headers['Authorization'] = 'Bearer fake-secret';
            options.queryParameters['api_key'] = 'fake-key';
            handler.next(options);
          },
        ),
      );
      await dio.get('/tv/1');
      expect(capture.last!.uri.host, 'bobtv.briconbric.com');
      expect(capture.last!.method, 'POST');
      expect(capture.last!.uri.toString(), isNot(contains('fake-key')));
      final payload = jsonDecode(capture.body);
      expect(payload['url'], contains('api_key=fake-key'));
      expect(payload['headers']['Authorization'], 'Bearer fake-secret');
      expect(capture.last!.headers.containsKey('Authorization'), false);
      expect(capture.last!.followRedirects, false);
      dio.close();
    },
  );

  test('media byte probes preserve Range and use the same gateway', () async {
    final capture = CaptureAdapter();
    final dio = Dio(BaseOptions(extra: {'egressKind': 'media'}));
    dio.httpClientAdapter = ServerEgressAdapter(capture);
    await dio.get(
      'https://media.example.org/live.ts',
      options: Options(headers: {'Range': 'bytes=0-65535'}),
    );
    expect(capture.last!.uri.host, 'bobtv.briconbric.com');
    expect(capture.last!.uri.queryParameters['kind'], 'media');
    expect(capture.last!.headers['Range'], 'bytes=0-65535');
    dio.close();
  });

  test(
    'media probes retain required origin headers inside the gateway',
    () async {
      final capture = CaptureAdapter();
      final dio = Dio(BaseOptions(extra: {'egressKind': 'media'}));
      dio.httpClientAdapter = ServerEgressAdapter(capture);
      await dio.head(
        'https://media.example.org/live.ts',
        options: Options(
          headers: {
            'Referer': 'https://tv.example.org/',
            'Origin': 'https://tv.example.org',
            'User-Agent': 'Required-TV-Agent',
            'Authorization': 'private-account-secret',
            'If-Range': 'known-etag',
          },
        ),
      );
      expect(capture.last!.method, 'HEAD');
      expect(jsonDecode(capture.last!.uri.queryParameters['headers']!), {
        'referer': 'https://tv.example.org/',
        'origin': 'https://tv.example.org',
        'user-agent': 'Required-TV-Agent',
      });
      expect(capture.last!.headers['If-Range'], 'known-etag');
      expect(
        capture.last!.uri.toString(),
        isNot(contains('private-account-secret')),
      );
      expect(capture.last!.headers.containsKey('Authorization'), false);
      dio.close();
    },
  );

  test(
    'last-resort guard blocks public direct connections before any socket',
    () async {
      final client = ServerEgress.createClient();
      try {
        await expectLater(
          client.getUrl(Uri.parse('https://api.github.com/repos/a/b')),
          throwsA(isA<SocketException>()),
        );
        expect(
          ServerEgress.canConnect(Uri.parse('https://bobtv.briconbric.com/')),
          true,
        );
        expect(
          ServerEgress.canConnect(Uri.parse('http://bobtv.briconbric.com/')),
          false,
        );
        expect(
          ServerEgress.canConnect(Uri.parse('http://192.168.1.9:7000/')),
          true,
        );
        expect(
          ServerEgress.canConnect(
            Uri.parse('https://bobtv.briconbric.com:49531/'),
          ),
          false,
        );
      } finally {
        client.close(force: true);
      }
    },
  );
}
