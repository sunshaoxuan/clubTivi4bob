import 'package:clubtivi/data/services/channel_country_ai_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('country lookup uses server without a local key', () async {
    SharedPreferences.setMockInitialValues({'bobtv_ai_enabled_v1': true});
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.uri.host, 'bobtv.briconbric.com');
          expect(options.headers.containsKey('Authorization'), isFalse);
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              data: {
                'state': 'done',
                'items': [
                  {'index': 0, 'country': '日本', 'confidence': .95},
                  {'index': 1, 'country': '美国', 'confidence': .45},
                ],
              },
            ),
          );
        },
      ),
    );
    final service = ChannelCountryAiService(dio: dio);
    final decisions = <String, String>{};
    await service.classifyUnknown(const [
      CountryNameInput('Known Japanese Network', 'General'),
      CountryNameInput('Ambiguous Network', 'General'),
    ], onBatch: decisions.addAll);
    expect(
      decisions[const CountryNameInput(
        'Known Japanese Network',
        'General',
      ).key],
      '日本',
    );
    expect(decisions.length, 1);
    expect(service.enabled, isTrue);
  });

  test('saved classifications survive server outages', () async {
    SharedPreferences.setMockInitialValues({
      'bobtv_country_ai_cache_v1': '{"unknown tv\\u0000general":"美国"}',
    });
    expect(
      (await ChannelCountryAiService()
          .cachedCountries())[const CountryNameInput(
        'Unknown TV',
        'General',
      ).key],
      '美国',
    );
  });
}
