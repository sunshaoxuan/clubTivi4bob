import 'dart:convert';
import 'package:clubtivi/data/services/country_collation_data.dart';
import 'package:clubtivi/data/services/country_name_index.dart';
import 'package:clubtivi/features/channels/compact_category_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final orders = <String, List<String>>{
    'en': [
      'Canada',
      'China',
      'France',
      'Germany',
      'Japan',
      'United Kingdom',
      'United States',
    ],
    'zh-CN': ['阿尔巴尼亚', '阿富汗', '安道尔', '美国', '日本', '英国'],
    'ja': ['アメリカ合衆国', 'イギリス', '韓国', '中国', 'ドイツ', '日本', 'フランス', '香港'],
    'fr': [
      'Allemagne',
      'Canada',
      'Chine',
      'États-Unis',
      'France',
      'Japon',
      'Royaume-Uni',
    ],
    'es': [
      'Alemania',
      'Canadá',
      'China',
      'España',
      'Estados Unidos',
      'Francia',
      'Japón',
      'Reino Unido',
    ],
    'ko': ['대한민국', '독일', '미국', '영국', '일본', '중국', '홍콩'],
  };
  for (final entry in orders.entries) {
    test(
      '${entry.key} country names follow that language rather than Chinese order',
      () {
        final values = entry.value.reversed.toList()
          ..sort((a, b) => CountryNameIndex.compare(a, b, locale: entry.key));
        expect(values, entry.value);
      },
    );
  }
  test(
    'native index groups use readings, Hangul, strokes and accented letters',
    () {
      expect(CountryNameIndex.initial('United States', locale: 'en'), 'U');
      expect(CountryNameIndex.initial('États-Unis', locale: 'fr'), 'E');
      expect(CountryNameIndex.initial('日本', locale: 'ja'), 'な');
      expect(CountryNameIndex.initial('中国', locale: 'ja'), 'た');
      expect(CountryNameIndex.initial('韓国', locale: 'ja'), 'か');
      expect(CountryNameIndex.initial('미국', locale: 'ko'), 'ㅁ');
      expect(CountryNameIndex.initial('日本', locale: 'zh-TW'), '4畫');
      expect(CountryNameIndex.initial('美國', locale: 'zh-TW'), '9畫');
      expect(CountryNameIndex.compareInitials('9畫', '10畫'), lessThan(0));
      expect(
        CountryNameIndex.matches('États-Unis', 'Etats', locale: 'fr'),
        isTrue,
      );
      expect(CountryNameIndex.matches('日本', 'jp', locale: 'ja'), isTrue);
      expect(CountryNameIndex.matches('日本', 'な', locale: 'ja'), isTrue);
      expect(CountryNameIndex.matches('미국', 'ㅁ', locale: 'ko'), isTrue);
    },
  );
  for (final locale in countryLocaleCollation.keys) {
    test(
      '$locale offline table covers the actual translated country vocabulary',
      () async {
        final strings =
            (jsonDecode(await rootBundle.loadString('assets/i18n/$locale.json'))
                    as Map)
                .cast<String, String>();
        final names = strings.entries
            .where((e) => e.key.startsWith('country:'))
            .map((e) => e.value)
            .toSet();
        expect(countryLocaleCollation[locale]!.keys.toSet(), names);
        expect(
          countryLocaleCollation[locale]!.values
              .map((e) => e.$1)
              .toSet()
              .length,
          names.length,
        );
      },
    );
  }
  testWidgets(
    'changing locale rebuilds country order while keeping selection IDs',
    (tester) async {
      var locale = 'en';
      final selected = <String>[];
      Widget view() => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            child: CompactCategoryRow(
              countryIndex: true,
              countryLocale: locale,
              level: 2,
              title: 'Countries',
              options: [
                for (final id in ['美国', '英国', '日本'])
                  CompactCategoryOption(
                    id: id,
                    label: locale == 'en'
                        ? {
                            '美国': 'United States',
                            '英国': 'United Kingdom',
                            '日本': 'Japan',
                          }[id]!
                        : {'美国': 'アメリカ合衆国', '英国': 'イギリス', '日本': '日本'}[id]!,
                    selected: id == '美国',
                    onTap: () => selected.add(id),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Japan')).dx,
        lessThan(tester.getTopLeft(find.text('United States')).dx),
      );
      locale = 'ja';
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('アメリカ合衆国')).dx,
        lessThan(tester.getTopLeft(find.text('日本')).dx),
      );
      await tester.tap(find.text('アメリカ合衆国'));
      expect(selected, ['美国']);
    },
  );
}
