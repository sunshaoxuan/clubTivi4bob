import 'package:clubtivi/data/services/channel_category_classifier.dart';
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
}
