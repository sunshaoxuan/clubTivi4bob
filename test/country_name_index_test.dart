import 'package:clubtivi/data/services/country_name_index.dart';
import 'package:clubtivi/data/services/country_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'indexes the displayed country name including country pronunciations',
    () {
      const cases = {
        '美国': 'M',
        'United States': 'U',
        '英国': 'Y',
        '香港': 'X',
        '澳门': 'A',
        '台湾': 'T',
        '秘鲁': 'B',
        '秘魯': 'B',
        '朝鲜': 'C',
        '阿根廷': 'A',
        '卡塔尔': 'K',
        '汤加': 'T',
        '不丹': 'B',
        '象牙海岸': 'X',
        '南韩': 'N',
        '蒙特內哥羅': 'M',
        '  brazil ': 'B',
        '未识别地区': '#',
        '': '#',
        '🌍': '#',
        '123': '#',
      };
      for (final entry in cases.entries) {
        expect(
          CountryNameIndex.initial(entry.key),
          entry.value,
          reason: entry.key,
        );
      }
    },
  );

  test(
    'every canonical country and alias destination has a navigation initial',
    () {
      final names = {
        ...CountryNames.byCode.values,
        ...CountryNames.aliases.values,
      }..remove('未识别地区');
      for (final name in names) {
        expect(
          CountryNameIndex.initial(name),
          matches(RegExp('^[A-Z]\$')),
          reason: name,
        );
      }
    },
  );

  test('name search accepts aliases, codes, case and single initials', () {
    expect(CountryNameIndex.matches('美国', 'United States'), isTrue);
    expect(CountryNameIndex.matches('美国', ' US '), isTrue);
    expect(CountryNameIndex.matches('美国', 'm'), isTrue);
    expect(CountryNameIndex.matches('科特迪瓦', '象牙海岸'), isTrue);
    expect(CountryNameIndex.matches('加拿大', '加'), isTrue);
    expect(CountryNameIndex.matches('美国', '加'), isFalse);
    expect(CountryNameIndex.matches('美国', 'uk'), isFalse);
    expect(CountryNameIndex.matches('美国', ''), isTrue);
  });
}
