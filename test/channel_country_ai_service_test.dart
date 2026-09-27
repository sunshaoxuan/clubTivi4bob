import 'package:clubtivi/data/services/channel_country_ai_service.dart';
import 'package:clubtivi/data/services/github_ai_crawler_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('AI country lookup stays disabled without existing runtime settings', () async {
    SharedPreferences.setMockInitialValues({});
    final service = ChannelCountryAiService(
      config: const OpenAiRuntimeConfig(
        baseUrl: '', apiKey: '', model: 'test',
      ),
    );
    var called = false;
    await service.classifyUnknown(
      const [CountryNameInput('Unknown TV', 'General')],
      onBatch: (_) => called = true,
    );
    expect(service.enabled, isFalse);
    expect(called, isFalse);
  });

  test('saved classifications are loaded by channel name and group', () async {
    SharedPreferences.setMockInitialValues({
      'bobtv_country_ai_cache_v1':
          '{"unknown tv\\u0000general":"美国"}',
    });
    final service = ChannelCountryAiService(
      config: const OpenAiRuntimeConfig(
        baseUrl: '', apiKey: '', model: 'test',
      ),
    );
    final key = const CountryNameInput('Unknown TV', 'General').key;
    expect((await service.cachedCountries())[key], '美国');
  });

  test('accepts confident country decisions and caches the result', () async {
    SharedPreferences.setMockInitialValues({});
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      handler.resolve(Response<Map<String, dynamic>>(
        requestOptions: options,
        data: {
          'choices': [
            {'message': {'content':
                '{"items":[{"index":0,"country":"日本","confidence":0.95},'
                '{"index":1,"country":"美国","confidence":0.45}]}'}}
          ],
        },
      ));
    }));
    final service = ChannelCountryAiService(
      config: const OpenAiRuntimeConfig(
        baseUrl: 'https://example.invalid/v1',
        apiKey: 'test-only-key',
        model: 'test',
      ),
      dio: dio,
    );
    final decisions = <String, String>{};
    await service.classifyUnknown(const [
      CountryNameInput('Known Japanese Network', 'General'),
      CountryNameInput('Ambiguous Network', 'General'),
    ], onBatch: decisions.addAll);
    expect(decisions[const CountryNameInput(
      'Known Japanese Network', 'General',
    ).key], '日本');
    expect(decisions.containsKey(const CountryNameInput(
      'Ambiguous Network', 'General',
    ).key), isFalse);
    final saved = await service.cachedCountries();
    expect(saved[const CountryNameInput(
      'Ambiguous Network', 'General',
    ).key], '未识别地区');
  });
}
