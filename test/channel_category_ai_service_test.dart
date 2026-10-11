import 'package:clubtivi/data/services/channel_category_ai_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'classification uses BobTV server without provider credentials',
    () async {
      SharedPreferences.setMockInitialValues({'bobtv_ai_enabled_v1': true});
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.uri.host, 'bobtv.briconbric.com');
            expect(options.uri.path, '/api/v1/server-tasks');
            expect(options.headers.containsKey('Authorization'), isFalse);
            expect((options.data as Map)['kind'], 'category');
            expect((options.data as Map).keys, isNot(contains('apiKey')));
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                data: {
                  'state': 'done',
                  'items': [
                    {'index': 0, 'category': '北京', 'confidence': .3},
                    {'index': 1, 'category': '青海', 'confidence': .95},
                  ],
                },
              ),
            );
          },
        ),
      );
      final service = ChannelCategoryAiService(dio: dio);
      final accepted = <String, String>{};
      const unknown = CategoryNameInput(id: 'nrbtv', name: 'NRBTV');
      await service.classifyUnknown([
        unknown,
        const CategoryNameInput(id: 'qinghai', name: 'Sample Qinghai TV'),
      ], onBatch: accepted.addAll);
      expect(accepted.containsKey(unknown.key), isFalse);
      expect(accepted.values, contains('青海'));
    },
  );

  test('server unavailable preserves unknown categories', () async {
    SharedPreferences.setMockInitialValues({'bobtv_ai_enabled_v1': true});
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(DioException(requestOptions: options));
        },
      ),
    );
    final service = ChannelCategoryAiService(dio: dio);
    var called = false;
    await service.classifyUnknown([
      const CategoryNameInput(id: 'x', name: 'Unknown'),
    ], onBatch: (_) => called = true);
    expect(called, isFalse);
    expect(await service.cachedCategories(), isEmpty);
  });
}
