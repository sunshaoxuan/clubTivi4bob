class ChannelCategoryClassifier {
  static const categories = <String>[
    '央视频道',
    '卫视频道',
    '地方频道',
    '港澳台频道',
    '国际频道',
    '体育频道',
    '新闻频道',
    '电影剧集',
    '少儿频道',
    '纪录频道',
    '广播电台',
    '其他频道',
  ];

  static const _platformGroups = <String>[
    '王者荣耀',
    '交友',
    '聊天电台',
    '英雄联盟',
    '星秀',
    '颜值',
    '派对',
    '一起看',
    '视频聊天',
    '和平精英',
    '聊天室',
    '虚拟singer',
    '虚拟日常',
    '唱见电台',
    '弹幕互动',
    '社交互动游戏',
    '热门游戏',
    '军事游戏',
    '策略游戏',
    '校园学习',
    'apex',
    'dota',
    '原神',
    '崩坏',
    '穿越火线',
    '永劫无间',
    '怪物猎人',
    'qq飞车',
    '龙之谷',
    '晶核',
    '火影忍者',
    '海上狼人杀',
    '最强nba',
    'lol云顶之弈',
  ];

  static const _regionalTerms = <String>[
    '北京',
    '天津',
    '上海',
    '重庆',
    '河北',
    '山西',
    '辽宁',
    '吉林',
    '黑龙江',
    '江苏',
    '浙江',
    '安徽',
    '福建',
    '江西',
    '山东',
    '河南',
    '湖北',
    '湖南',
    '广东',
    '海南',
    '四川',
    '贵州',
    '云南',
    '陕西',
    '甘肃',
    '青海',
    '内蒙古',
    '广西',
    '西藏',
    '宁夏',
    '新疆',
    '省内',
    '地方',
    '本地',
    '省市',
    '城市',
  ];

  static String classify({
    required String name,
    String? groupTitle,
    String? tvgId,
    String? streamUrl,
  }) {
    final text = '$name ${groupTitle ?? ''} ${tvgId ?? ''}'.toLowerCase();
    final group = (groupTitle ?? '').toLowerCase();

    if (isPlatformLivestream(
      name: name,
      groupTitle: groupTitle,
      streamUrl: streamUrl,
    )) {
      return '网络直播';
    }

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
      '港澳台',
      '香港',
      '澳门',
      '澳門',
      '台湾',
      '台灣',
      'tvb',
      '翡翠台',
      '明珠台',
      'viutv',
      'rthk',
    ])) {
      return '港澳台频道';
    }
    if (_containsAny(text, _regionalTerms)) {
      return '地方频道';
    }
    if (_isInternationalTelevision(name, group)) {
      return '国际频道';
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
    if (_containsAny(text, const ['广播', '电台', 'radio', 'fm ', 'am '])) {
      return '广播电台';
    }
    return '其他频道';
  }

  static bool isPlatformLivestream({
    required String name,
    String? groupTitle,
    String? streamUrl,
  }) {
    final group = (groupTitle ?? '').toLowerCase();
    if (_containsAny(group, _platformGroups)) return true;
    final host = Uri.tryParse(streamUrl ?? '')?.host.toLowerCase() ?? '';
    if (host == '107.173.156.246') return true;
    return host.endsWith('.huya.com') ||
        host.endsWith('.douyu.com') ||
        host.endsWith('.douyucdn.cn') ||
        host.endsWith('.bilivideo.com') ||
        host.endsWith('.acgvideo.com') ||
        host.endsWith('.kwimgs.com');
  }

  static bool isClearlyNonTelevisionRoute({
    required String name,
    String? groupTitle,
    required String streamUrl,
  }) {
    if (isPlatformLivestream(
      name: name,
      groupTitle: groupTitle,
      streamUrl: streamUrl,
    )) {
      return true;
    }
    final uri = Uri.tryParse(streamUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return true;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    final rootPageWithFragment =
        uri.fragment.isNotEmpty &&
        (uri.path.isEmpty || uri.path == '/') &&
        uri.query.isEmpty;
    if (rootPageWithFragment) return true;
    final path = uri.path.toLowerCase();
    return path.endsWith('.html') || path.endsWith('.htm');
  }

  static bool _isInternationalTelevision(String name, String group) {
    if (_containsAny(group, const [
      '国际频道',
      'international',
      'general',
      'legislative',
      'religious',
    ])) {
      return true;
    }
    final lowerName = name.toLowerCase();
    if (RegExp(r'[\u3400-\u9fff]').hasMatch(lowerName)) return false;
    return RegExp(
      r'(^|\s|[-_])(tv|television|channel)(\s|$|[-_0-9])|^(rai|rtl|fox|ion)\b',
    ).hasMatch(lowerName);
  }

  static bool _containsAny(String text, List<String> values) =>
      values.any(text.contains);
}
