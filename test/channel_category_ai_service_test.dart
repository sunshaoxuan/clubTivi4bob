import 'package:clubtivi/data/services/ai_runtime_settings.dart';
import 'package:clubtivi/data/services/channel_category_ai_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const unknown = CategoryNameInput(id: 'nrbtv', name: 'NRBTV');

  test('rejects remote plaintext AI endpoints', () {
    expect(AiRuntimeSettings.isSafeEndpoint('http://example.com/v1'), isFalse);
    expect(AiRuntimeSettings.isSafeEndpoint('http://127.0.0.1:60813/v1'), isTrue);
    expect(AiRuntimeSettings.isSafeEndpoint('https://example.com/v1'), isTrue);
    expect(AiRuntimeSettings.isSafeEndpoint('https://user:pass@example.com/v1'), isFalse);
  });

  test('disabled AI leaves unknown categories untouched', () async {
    SharedPreferences.setMockInitialValues({});
    final service = ChannelCategoryAiService(settings: const AiRuntimeValues(
      baseUrl: '', model: '', apiKey: '', enabled: false,
    ));
    var called = false;
    await service.classifyUnknown([unknown], onBatch: (_) => called = true);
    expect(called, isFalse);
    expect(await service.cachedCategories(), isEmpty);
  });

  test('accepts only confident explicit categories', () async {
    SharedPreferences.setMockInitialValues({});
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      handler.resolve(Response<Map<String, dynamic>>(
        requestOptions: options,
        data: {
          'choices': [
            {'message': {'content':
              '{"items":[{"index":0,"category":"北京","confidence":0.3},'
              '{"index":1,"category":"青海","confidence":0.95}]}'}}
          ],
        },
      ));
    }));
    final service = ChannelCategoryAiService(
      dio: dio,
      settings: const AiRuntimeValues(
        baseUrl: 'https://example.com/v1',
        model: 'test', apiKey: 'test-only-key', enabled: true,
      ),
    );
    final accepted = <String, String>{};
    await service.classifyUnknown([
      unknown,
      const CategoryNameInput(id: 'qinghai', name: 'Sample Qinghai TV'),
    ], onBatch: accepted.addAll);
    expect(accepted.containsKey(unknown.key), isFalse);
    expect(accepted.values, contains('青海'));
  });
}
