import 'package:clubtivi/data/services/channel_category_classifier.dart';
import 'package:clubtivi/data/services/manual_channel_category.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('country aliases share Simplified Chinese destinations and suggestions', () {
    for (final alias in ['United States', 'USA', 'us', '美國', '美国']) {
      final destination = ChannelCategoryDestination.fromGroup('国际 / $alias / 新闻 / 财经')!;
      expect(destination.group, '国际 / 美国 / 新闻 / 财经');
      expect(destination.country, '美国');
    }
    final suggestions = ChannelCategoryDestination.children([], existing: [
      ChannelCategoryDestination(['United States', '新闻']),
      ChannelCategoryDestination(['美國', '电影']),
      ChannelCategoryDestination(['美国', '体育']),
    ]);
    expect(suggestions.where((name) => name == '美国'), hasLength(1));
    expect(suggestions, isNot(contains('United States')));
  });

  test('full country map handles previously English catalog countries', () {
    for (final entry in {
      'Afghanistan': '阿富汗', 'Kuwait': '科威特', 'United Arab Emirates': '阿拉伯联合酋长国',
      'Czech Republic': '捷克', 'Saint Kitts and Nevis': '圣基茨和尼维斯',
      'Republic of the Congo': '刚果（布）',
      'Democratic Republic of the Congo': '刚果（金）',
    }.entries) {
      expect(ChannelCategoryClassifier.normalizeCountryName(entry.key), entry.value);
      expect(ChannelCategoryClassifier.internationalCountryFor(name: 'Station', groupTitle: '国际 / ${entry.key} / 新闻'), entry.value);
    }
    expect(ChannelCategoryClassifier.normalizeCountryName('自定义地区'), '自定义地区');
    expect(ChannelCategoryDestination(['Kuwait', 'English News']).path, ['科威特', 'English News']);
  });
}
