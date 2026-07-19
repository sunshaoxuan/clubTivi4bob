class ChannelCategoryClassifier {
  static const categories = <String>[
    '央视频道',
    '卫视频道',
    '地方频道',
    '体育频道',
    '新闻频道',
    '电影剧集',
    '少儿频道',
    '纪录频道',
    '其他频道',
  ];

  static String classify({
    required String name,
    String? groupTitle,
    String? tvgId,
  }) {
    final text = '$name ${groupTitle ?? ''} ${tvgId ?? ''}'.toLowerCase();

    if (RegExp(r'cctv\s*[-_]?\s*\d').hasMatch(text) ||
        text.contains('央视') ||
        text.contains('中央电视') ||
        text.contains('cgtn')) {
      return '央视频道';
    }
    if (text.contains('卫视') || text.contains('satellite')) {
      return '卫视频道';
    }
    if (_containsAny(text, const [
      '体育',
      '赛事',
      '足球',
      '篮球',
      '网球',
      '高尔夫',
      'sports',
      'sport',
    ])) {
      return '体育频道';
    }
    if (_containsAny(text, const ['新闻', '资讯', 'news'])) {
      return '新闻频道';
    }
    if (_containsAny(text, const [
      '电影',
      '影院',
      '影视',
      '剧场',
      '电视剧',
      'movie',
      'cinema',
    ])) {
      return '电影剧集';
    }
    if (_containsAny(text, const [
      '少儿',
      '卡通',
      '动漫',
      '动画',
      '儿童',
      'kids',
      'cartoon',
    ])) {
      return '少儿频道';
    }
    if (_containsAny(text, const ['纪录', '纪实', 'documentary', 'discovery'])) {
      return '纪录频道';
    }
    if (_containsAny(text, const ['地方', '本地', '省市', '城市', 'local', 'city'])) {
      return '地方频道';
    }
    return '其他频道';
  }

  static bool _containsAny(String text, List<String> values) =>
      values.any(text.contains);
}
