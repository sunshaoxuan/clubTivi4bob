import 'package:clubtivi/data/services/channel_category_classifier.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses one stable content dimension for global categories', () {
    expect(
      ChannelCategoryClassifier.classify(
        name: 'CCTV5 4K',
        groupTitle: '4K频道',
        tvgId: 'CCTV5',
      ),
      '央视频道',
    );
    expect(ChannelCategoryClassifier.classify(name: '湖南卫视 4K'), '卫视频道');
    expect(ChannelCategoryClassifier.classify(name: '咪咕足球赛事'), '体育频道');
    expect(ChannelCategoryClassifier.classify(name: '上海新闻综合'), '地方频道');
    expect(ChannelCategoryClassifier.classify(name: '金鹰卡通'), '少儿频道');
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
      '港澳台频道',
    );
    expect(
      ChannelCategoryClassifier.classify(
        name: 'Rai 2',
        groupTitle: 'International',
      ),
      '国际频道',
    );
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
      ]);

      final central = await database.getChannelCategoryCandidates('央视频道');
      expect(central.map((channel) => channel.id), ['central']);
      final movies = await database.getChannelCategoryCandidates('电影剧集');
      expect(movies.map((channel) => channel.id), ['movie']);
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
      expect(await database.purgePlatformLivestreamChannels(), 1);
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
}
