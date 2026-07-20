import 'package:clubtivi/data/services/channel_category_classifier.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses one stable geography-first category dimension', () {
    expect(
      ChannelCategoryClassifier.classify(
        name: 'CCTV5 4K',
        groupTitle: '4K频道',
        tvgId: 'CCTV5',
      ),
      '央视',
    );
    expect(ChannelCategoryClassifier.classify(name: '湖南卫视 4K'), '湖南');
    expect(ChannelCategoryClassifier.classify(name: '咪咕足球赛事'), '其他');
    expect(ChannelCategoryClassifier.classify(name: '上海新闻综合'), '上海');
    expect(ChannelCategoryClassifier.classify(name: '金鹰卡通'), '湖南');
    expect(
      ChannelCategoryClassifier.classify(
        name: '白白wuhu',
        groupTitle: '颜值（横屏）',
        streamUrl: 'http://107.173.156.246/live/1.m3u8',
      ),
      '网络直播',
    );
    expect(
      ChannelCategoryClassifier.classify(name: 'TVB星河', groupTitle: '港澳台频道'),
      '港澳台',
    );
    expect(
      ChannelCategoryClassifier.classify(
        name: 'Rai 2',
        groupTitle: 'International',
      ),
      '国际',
    );
    expect(
      ChannelCategoryClassifier.classify(name: 'France 24', groupTitle: '国际'),
      '国际',
    );
    expect(
      ChannelCategoryClassifier.classify(name: '澳门资讯', groupTitle: '🌊港·澳·台'),
      '港澳台',
    );
  });

  test('does not infer a central channel from an upstream group name', () {
    expect(
      ChannelCategoryClassifier.classify(name: '东方卫视', groupTitle: '咪咕央视'),
      '上海',
    );
    expect(
      ChannelCategoryClassifier.classify(name: '上海新闻综合', groupTitle: '央视频道'),
      '上海',
    );
    expect(
      ChannelCategoryClassifier.classify(name: 'CETV-1', groupTitle: '央视频道'),
      '数字',
    );
  });

  test('recognizes audio-only radio channel metadata and URLs', () {
    expect(
      ChannelCategoryClassifier.isRadioChannel(name: 'BBC Radio 2'),
      isTrue,
    );
    expect(ChannelCategoryClassifier.classify(name: '北京人民广播电台'), '广播');
    expect(
      ChannelCategoryClassifier.isRadioChannel(
        name: 'Music Service',
        streamUrl: 'https://example.com/live/channel.aac?token=abc',
      ),
      isTrue,
    );
  });

  test('sorts central channels by service number and quality variant', () {
    String key(String name) => ChannelCategoryClassifier.sortKeyForCategory(
      category: '央视',
      name: name,
    );

    expect(key('CCTV1').compareTo(key('CCTV2')), lessThan(0));
    expect(key('CCTV5').compareTo(key('CCTV5 4K')), lessThan(0));
    expect(key('CCTV5 4K').compareTo(key('CCTV5+')), lessThan(0));
    expect(key('CCTV17').compareTo(key('CCTV 4K')), lessThan(0));
    expect(key('CCTV 8K').compareTo(key('CGTN')), lessThan(0));
  });

  test('sorts a provincial satellite channel before local channels', () {
    String key(String name) => ChannelCategoryClassifier.sortKeyForCategory(
      category: '湖南',
      name: name,
    );

    expect(key('湖南卫视').compareTo(key('湖南经视')), lessThan(0));
    expect(key('湖南经视').compareTo(key('长沙新闻')), lessThan(0));
  });

  test(
    'database materializes only candidates for the selected category',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.upsertProvider(
        db.ProvidersCompanion.insert(id: 'test', name: 'Test', type: 'm3u'),
      );
      await database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'central',
          providerId: 'test',
          name: 'CCTV5 体育',
          streamUrl: 'https://example.com/cctv5.m3u8',
        ),
        db.ChannelsCompanion.insert(
          id: 'satellite',
          providerId: 'test',
          name: '湖南卫视',
          streamUrl: 'https://example.com/hunan.m3u8',
        ),
        db.ChannelsCompanion.insert(
          id: 'movie',
          providerId: 'test',
          name: '经典电影',
          streamUrl: 'https://example.com/movie.m3u8',
        ),
        db.ChannelsCompanion.insert(
          id: 'mixed-group',
          providerId: 'test',
          name: '上海新闻综合',
          groupTitle: const Value('央视频道'),
          streamUrl: 'https://example.com/shanghai.m3u8',
        ),
        db.ChannelsCompanion.insert(
          id: 'audio-url',
          providerId: 'test',
          name: 'Music Service',
          streamUrl: 'https://example.com/live/music.aac',
        ),
        db.ChannelsCompanion.insert(
          id: 'digital',
          providerId: 'test',
          name: 'CETV-1',
          streamUrl: 'https://example.com/cetv.m3u8',
        ),
      ]);

      final central = await database.getChannelCategoryCandidates('央视');
      expect(central.map((channel) => channel.id), ['central']);
      final hunan = await database.getChannelCategoryCandidates('湖南');
      expect(hunan.map((channel) => channel.id), ['satellite']);
      final others = await database.getChannelCategoryCandidates('其他');
      expect(others.map((channel) => channel.id), contains('movie'));
      final radio = await database.getChannelCategoryCandidates('广播');
      expect(radio.map((channel) => channel.id), ['audio-url']);
      final digital = await database.getChannelCategoryCandidates('数字');
      expect(digital.map((channel) => channel.id), ['digital']);
    },
  );

  test(
    'filters platform livestreams during import and purges old rows',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.upsertProvider(
        db.ProvidersCompanion.insert(id: 'test', name: 'Test', type: 'm3u'),
      );
      final platform = db.ChannelsCompanion.insert(
        id: 'platform',
        providerId: 'test',
        name: '直播主播',
        groupTitle: const Value('王者荣耀'),
        streamUrl: 'http://107.173.156.246/live/1.m3u8',
      );
      await database.upsertChannels([platform]);
      expect(await database.getAllChannels(), isEmpty);

      await database.into(database.channels).insert(platform);
      expect(await database.purgeRejectedNonTelevisionChannels(), 1);
      expect(await database.getAllChannels(), isEmpty);
    },
  );

  test('rejects website fragments and HTML pages as television routes', () {
    expect(
      ChannelCategoryClassifier.isClearlyNonTelevisionRoute(
        name: '分享频道',
        streamUrl: 'http://iptv.example.cn/#room-123',
      ),
      isTrue,
    );
    expect(
      ChannelCategoryClassifier.isClearlyNonTelevisionRoute(
        name: '推广页',
        streamUrl: 'https://example.cn/watch/index.html',
      ),
      isTrue,
    );
    expect(
      ChannelCategoryClassifier.isClearlyNonTelevisionRoute(
        name: '地方电视',
        streamUrl: 'https://example.cn/live/channel.m3u8?token=abc',
      ),
      isFalse,
    );
  });

  test('removes requested non-television catalog content', () {
    for (final channel in <({String name, String group})>[
      (name: '咪咕直播18', group: '咪咕直播'),
      (name: '熊猫直播', group: '央视节目'),
      (name: '游戏风云', group: '数字频道'),
      (name: '哒啵电竞', group: 'NewTV频道'),
      (name: '环球购物', group: '购物频道'),
    ]) {
      expect(
        ChannelCategoryClassifier.isClearlyNonTelevisionRoute(
          name: channel.name,
          groupTitle: channel.group,
          streamUrl: 'https://example.cn/live/channel.m3u8',
        ),
        isTrue,
      );
    }
  });

  test('keeps adult and GitHub discovery groups by request', () {
    expect(
      ChannelCategoryClassifier.isClearlyNonTelevisionRoute(
        name: 'AdultIPTV.net Woman',
        groupTitle: 'XXX',
        streamUrl: 'http://107.173.156.246/live/adult.m3u8',
      ),
      isFalse,
    );
    expect(
      ChannelCategoryClassifier.isClearlyNonTelevisionRoute(
        name: '游戏风云',
        groupTitle: 'GitHub 智慧发现',
        streamUrl: 'http://107.173.156.246/live/discovered.m3u8',
      ),
      isFalse,
    );
  });
}
