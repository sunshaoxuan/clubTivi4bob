import 'package:clubtivi/data/services/channel_category_classifier.dart';
import 'package:clubtivi/data/services/manual_channel_category.dart';
import 'package:clubtivi/data/services/channel_presentation_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unknown root and legacy China other are global destinations', () {
    for (final group in ['其他', '其他 / 待识别', '中国 / 其他']) {
      final destination = ChannelCategoryDestination.fromGroup(group)!;
      expect(destination.category, '其他');
      expect(destination.country, '未识别地区');
      expect(destination.group.startsWith('中国'), isFalse);
    }
    expect(ChannelCategoryDestination.children(['中国']), isNot(contains('其他')));
    expect(ChannelCategoryDestination.children(['美国']), containsAll(['电视', '广播']));
    expect(ChannelCategoryDestination.children(['美国','电视']), contains('新闻'));
  });

  test('television level preserves the depth of existing custom categories', () {
    final path = ['美国','电视','节目','地区','专题','子类','末级'];
    final destination = ChannelCategoryDestination(path);
    expect(destination.valid, isTrue);
    expect(ChannelCategoryDestination.fromGroup(destination.group)!.path, path);
  });

  test('radio geography and explicit media do not default to Chinese television', () {
    expect(ChannelCategoryClassifier.classify(name:'Radio Station', tvgId:'station.us'), '国际');
    expect(ChannelCategoryClassifier.classify(name:'Radio Station'), '其他');
    expect(ChannelCategoryClassifier.classify(name:'北京人民广播电台'), '广播');
    expect(ChannelCategoryClassifier.classify(name:'CCTV',groupTitle:'其他 / 待识别'), '其他');
    expect(ChannelCategoryClassifier.internationalMediaFor(name:'Station',groupTitle:'国际 / 英国 / 广播'), '广播');
    expect(ChannelCategoryClassifier.internationalMediaFor(name:'Radio Television',groupTitle:'国际 / 英国 / 电视 / 新闻'), '电视');
    expect(ChannelCategoryClassifier.internationalGenreFor('国际 / 英国 / 电视 / 新闻'), '新闻');
  });

  test('new television hierarchy keeps card continuity and separates radio', () {
    ChannelPresentationRoute route(String id,String group) => ChannelPresentationRoute(
      id:id,name:'Example',url:'https://media.example.org/$id',catalogId:id,group:group);
    final keys = ChannelPresentationIdentity.keys([
      route('old','国际 / 美国 / 新闻'),route('tv','国际 / 美国 / 电视 / 新闻'),
      route('radio','国际 / 美国 / 广播'),
    ]);
    expect(keys['old'],keys['tv']);
    expect(keys['radio'],isNot(keys['tv']));
  });
}
