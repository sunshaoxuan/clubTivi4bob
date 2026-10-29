import 'package:clubtivi/data/services/server_task_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'production requests retain the BobTV endpoint and exact recovery identity',
    () async {
      final dio = Dio();
      addTearDown(dio.close);
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            expect(
              request.uri.toString(),
              'https://bobtv.briconbric.com/api/v1/server-tasks',
            );
            expect(request.method, 'POST');
            expect(request.data, {
              'kind': 'recover',
              'inputs': [
                {
                  'channelId': 'my-aec',
                  'failedUrl': 'https://example.org/old.m3u8',
                },
              ],
            });
            handler.resolve(
              Response(
                requestOptions: request,
                data: <String, dynamic>{'state': 'queued'},
              ),
            );
          },
        ),
      );
      expect(
        await ServerTaskClient(dio: dio).submit('recover', [
          {'channelId': 'my-aec', 'failedUrl': 'https://example.org/old.m3u8'},
        ]),
        {'state': 'queued'},
      );
    },
  );

  test(
    'isolated acceptance API is injectable without rewriting production URLs',
    () async {
      final dio = Dio();
      addTearDown(dio.close);
      final id = 'a' * 64;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            expect(
              request.uri.toString(),
              'http://127.0.0.1:18371/api/v1/server-tasks/$id',
            );
            handler.resolve(
              Response(
                requestOptions: request,
                data: <String, dynamic>{'state': 'done'},
              ),
            );
          },
        ),
      );
      final client = ServerTaskClient(
        dio: dio,
        baseUri: Uri.parse('http://127.0.0.1:18371'),
      );
      expect(await client.result(id), {'state': 'done'});
      expect(() => client.result('../status'), throwsFormatException);
    },
  );
}
