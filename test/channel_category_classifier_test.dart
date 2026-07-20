import 'package:clubtivi/data/services/channel_category_classifier.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
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
    expect(ChannelCategoryClassifier.classify(name: '上海新闻综合'), '新闻频道');
    expect(ChannelCategoryClassifier.classify(name: '金鹰卡通'), '少儿频道');
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
}
