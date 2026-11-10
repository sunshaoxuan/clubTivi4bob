import 'package:clubtivi/core/i18n/app_language.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'host locale precedes timezone and honors script and preference order',
    () {
      expect(
        AppLanguage.resolve([const Locale('fr', 'CA')], 'Asia/Tokyo'),
        AppLanguage.french,
      );
      expect(
        AppLanguage.resolve([
          const Locale('de'),
          const Locale('es', 'MX'),
        ], 'Asia/Tokyo'),
        AppLanguage.spanish,
      );
      expect(
        AppLanguage.resolve([const Locale('zh', 'HK')], null),
        AppLanguage.traditionalChinese,
      );
      expect(
        AppLanguage.resolve([
          const Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hans',
            countryCode: 'TW',
          ),
        ], null),
        AppLanguage.simplifiedChinese,
      );
      expect(AppLanguage.resolve([], 'Asia/Tokyo'), AppLanguage.japanese);
      expect(
        AppLanguage.resolve([], 'Korea Standard Time'),
        AppLanguage.korean,
      );
      expect(
        AppLanguage.resolve([], 'America/Mexico_City'),
        AppLanguage.spanish,
      );
      expect(AppLanguage.resolve([], 'UTC'), AppLanguage.english);
    },
  );

  test('each selectable language has a bundled message catalog', () async {
    for (final language in AppLanguage.values) {
      expect(AppLanguage.fromTag(language.tag), language);
      expect(
        await AppMessages.delegate.load(language.locale),
        isA<AppMessages>(),
      );
    }
    expect(AppLanguage.fromTag('system'), isNull);
  });
}
