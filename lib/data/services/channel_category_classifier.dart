class ChannelCategoryClassifier {
  static const provinceCategories = <String>[
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
  ];

  static const categories = <String>[
    '央视',
    ...provinceCategories,
    '港澳台',
    '国际',
    '广播',
    '数字',
    '其他',
  ];

  static const _provinceAliases = <String, List<String>>{
    '北京': ['北京', '京视', 'btv'],
    '天津': ['天津', '津云', 'tjtv'],
    '上海': ['上海', '东方卫视', '上视', '五星体育', '第一财经', '哈哈炫动'],
    '重庆': ['重庆', 'cqtv'],
    '河北': [
      '河北',
      '石家庄',
      '唐山',
      '秦皇岛',
      '邯郸',
      '邢台',
      '保定',
      '张家口',
      '承德',
      '沧州',
      '廊坊',
      '衡水',
    ],
    '山西': [
      '山西',
      '太原',
      '大同',
      '阳泉',
      '长治',
      '晋城',
      '朔州',
      '晋中',
      '运城',
      '忻州',
      '临汾',
      '吕梁',
    ],
    '辽宁': [
      '辽宁',
      '沈阳',
      '大连',
      '鞍山',
      '抚顺',
      '本溪',
      '丹东',
      '锦州',
      '营口',
      '阜新',
      '辽阳',
      '盘锦',
      '铁岭',
      '葫芦岛',
    ],
    '吉林': ['吉林', '长春', '四平', '辽源', '通化', '白山', '松原', '白城', '延边'],
    '黑龙江': [
      '黑龙江',
      '哈尔滨',
      '齐齐哈尔',
      '牡丹江',
      '佳木斯',
      '大庆',
      '鸡西',
      '鹤岗',
      '双鸭山',
      '伊春',
      '七台河',
      '黑河',
      '绥化',
      '大兴安岭',
    ],
    '江苏': [
      '江苏',
      '南京',
      '无锡',
      '徐州',
      '常州',
      '苏州',
      '南通',
      '连云港',
      '淮安',
      '盐城',
      '扬州',
      '镇江',
      '泰州',
      '宿迁',
    ],
    '浙江': [
      '浙江',
      '杭州',
      '宁波',
      '温州',
      '嘉兴',
      '湖州',
      '绍兴',
      '金华',
      '衢州',
      '舟山',
      '台州',
      '丽水',
    ],
    '安徽': [
      '安徽',
      '合肥',
      '芜湖',
      '蚌埠',
      '淮南',
      '马鞍山',
      '淮北',
      '铜陵',
      '安庆',
      '黄山',
      '滁州',
      '阜阳',
      '宿州',
      '六安',
      '亳州',
      '池州',
      '宣城',
    ],
    '福建': ['福建', '东南卫视', '福州', '厦门', '莆田', '三明', '泉州', '漳州', '南平', '龙岩', '宁德'],
    '江西': [
      '江西',
      '南昌',
      '景德镇',
      '萍乡',
      '九江',
      '新余',
      '鹰潭',
      '赣州',
      '吉安',
      '宜春',
      '抚州',
      '上饶',
    ],
    '山东': [
      '山东',
      '济南',
      '青岛',
      '淄博',
      '枣庄',
      '东营',
      '烟台',
      '潍坊',
      '济宁',
      '泰安',
      '威海',
      '日照',
      '临沂',
      '德州',
      '聊城',
      '滨州',
      '菏泽',
    ],
    '河南': [
      '河南',
      '郑州',
      '开封',
      '洛阳',
      '平顶山',
      '安阳',
      '鹤壁',
      '新乡',
      '焦作',
      '濮阳',
      '许昌',
      '漯河',
      '三门峡',
      '南阳',
      '商丘',
      '信阳',
      '周口',
      '驻马店',
      '济源',
    ],
    '湖北': [
      '湖北',
      '武汉',
      '黄石',
      '十堰',
      '宜昌',
      '襄阳',
      '鄂州',
      '荆门',
      '孝感',
      '荆州',
      '黄冈',
      '咸宁',
      '随州',
      '恩施',
      '仙桃',
      '潜江',
      '天门',
      '神农架',
    ],
    '湖南': [
      '湖南',
      '长沙',
      '株洲',
      '湘潭',
      '衡阳',
      '邵阳',
      '岳阳',
      '常德',
      '张家界',
      '益阳',
      '郴州',
      '永州',
      '怀化',
      '娄底',
      '湘西',
      '金鹰卡通',
    ],
    '广东': [
      '广东',
      '大湾区卫视',
      '珠江',
      '深圳',
      '广州',
      '韶关',
      '汕头',
      '佛山',
      '江门',
      '湛江',
      '茂名',
      '肇庆',
      '惠州',
      '梅州',
      '汕尾',
      '河源',
      '阳江',
      '清远',
      '东莞',
      '中山',
      '潮州',
      '揭阳',
      '云浮',
      '南方卫视',
    ],
    '海南': ['海南', '旅游卫视', '海口', '三亚', '三沙', '儋州'],
    '四川': [
      '四川',
      '成都',
      '自贡',
      '攀枝花',
      '泸州',
      '德阳',
      '绵阳',
      '广元',
      '遂宁',
      '内江',
      '乐山',
      '南充',
      '眉山',
      '宜宾',
      '广安',
      '达州',
      '雅安',
      '巴中',
      '资阳',
      '阿坝',
      '甘孜',
      '凉山',
    ],
    '贵州': ['贵州', '贵阳', '六盘水', '遵义', '安顺', '毕节', '铜仁', '黔西南', '黔东南', '黔南'],
    '云南': [
      '云南',
      '昆明',
      '曲靖',
      '玉溪',
      '保山',
      '昭通',
      '丽江',
      '普洱',
      '临沧',
      '楚雄',
      '红河',
      '文山',
      '西双版纳',
      '大理',
      '德宏',
      '怒江',
      '迪庆',
    ],
    '陕西': [
      '陕西',
      '农林卫视',
      '西安',
      '铜川',
      '宝鸡',
      '咸阳',
      '渭南',
      '延安',
      '汉中',
      '榆林',
      '安康',
      '商洛',
    ],
    '甘肃': [
      '甘肃',
      '兰州',
      '嘉峪关',
      '金昌',
      '白银',
      '天水',
      '武威',
      '张掖',
      '平凉',
      '酒泉',
      '庆阳',
      '定西',
      '陇南',
      '临夏',
      '甘南',
    ],
    '青海': ['青海', '西宁', '海东', '海北', '黄南', '海南州', '果洛', '玉树', '海西'],
    '内蒙古': [
      '内蒙古',
      '呼和浩特',
      '包头',
      '乌海',
      '赤峰',
      '通辽',
      '鄂尔多斯',
      '呼伦贝尔',
      '巴彦淖尔',
      '乌兰察布',
      '兴安盟',
      '锡林郭勒',
      '阿拉善',
    ],
    '广西': [
      '广西',
      '南宁',
      '柳州',
      '桂林',
      '梧州',
      '北海',
      '防城港',
      '钦州',
      '贵港',
      '玉林',
      '百色',
      '贺州',
      '河池',
      '来宾',
      '崇左',
    ],
    '西藏': ['西藏', '拉萨', '日喀则', '昌都', '林芝', '山南', '那曲', '阿里'],
    '宁夏': ['宁夏', '银川', '石嘴山', '吴忠', '固原', '中卫'],
    '新疆': [
      '新疆',
      '兵团卫视',
      '乌鲁木齐',
      '克拉玛依',
      '吐鲁番',
      '哈密',
      '昌吉',
      '博尔塔拉',
      '巴音郭楞',
      '阿克苏',
      '克孜勒苏',
      '喀什',
      '和田',
      '伊犁',
      '塔城',
      '阿勒泰',
      '石河子',
    ],
  };

  static const _centralTerms = ['cctv', '央视', '中央电视', 'cgtn'];
  static const _hongKongMacauTaiwanTerms = [
    '港澳台',
    '港澳',
    '港·澳·台',
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
  ];
  static const _digitalTerms = [
    '数字频道',
    '数字电视',
    '付费频道',
    'cetv',
    'chc',
    'newtv',
    'ihot',
    'sitv',
    'bestv',
    '中国教育',
    '教育电视',
    '风云足球',
    '风云音乐',
    '风云剧场',
    '怀旧剧场',
    '第一剧场',
    '世界地理',
    '电视指南',
    '女性时尚',
    '文化精品',
    '兵器科技',
    '央视台球',
    '高尔夫网球',
    '家庭影院',
    '梨园',
    '武术世界',
    '文物宝库',
    '天元围棋',
    '先锋乒羽',
    '快乐垂钓',
    '茶频道',
    '摄影频道',
    '都市剧场',
    '欢笑剧场',
    '动漫秀场',
    '法治天地',
    '金色学堂',
    '生活时尚',
    '极速汽车',
    '劲爆体育',
    '全纪实',
    '东方财经',
    '证券资讯',
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

  static String classify({
    required String name,
    String? groupTitle,
    String? tvgId,
    String? streamUrl,
  }) {
    final text = '$name ${groupTitle ?? ''} ${tvgId ?? ''}'.toLowerCase();
    final identity = '$name ${tvgId ?? ''}'.toLowerCase();
    final group = (groupTitle ?? '').toLowerCase();

    if (isPlatformLivestream(
      name: name,
      groupTitle: groupTitle,
      streamUrl: streamUrl,
    )) {
      return '网络直播';
    }

    if (isRadioChannel(
      name: name,
      groupTitle: groupTitle,
      tvgId: tvgId,
      streamUrl: streamUrl,
    )) {
      return '广播';
    }

    if (_containsAny(identity, _centralTerms)) {
      return '央视';
    }
    if (_containsAny(text, _hongKongMacauTaiwanTerms)) {
      return '港澳台';
    }
    final province = provinceFor(
      name: name,
      groupTitle: groupTitle,
      tvgId: tvgId,
    );
    if (province != null) {
      return province;
    }
    if (_isInternationalTelevision(name, group)) {
      return '国际';
    }
    if (_containsAny(text, _digitalTerms)) {
      return '数字';
    }
    return '其他';
  }

  static String? provinceFor({
    required String name,
    String? groupTitle,
    String? tvgId,
  }) {
    final identity = '$name ${tvgId ?? ''}'.toLowerCase();
    String? bestProvince;
    var bestLength = 0;
    for (final province in provinceCategories) {
      for (final alias in _provinceAliases[province]!) {
        if (identity.contains(alias) && alias.length > bestLength) {
          bestProvince = province;
          bestLength = alias.length;
        }
      }
    }
    if (bestProvince != null) return bestProvince;
    final group = (groupTitle ?? '').toLowerCase();
    for (final province in provinceCategories) {
      for (final alias in _provinceAliases[province]!) {
        if (group.contains(alias) && alias.length > bestLength) {
          bestProvince = province;
          bestLength = alias.length;
        }
      }
    }
    return bestProvince;
  }

  static List<String>? candidateTermsForCategory(String category) {
    if (category == '央视') return _centralTerms;
    if (category == '港澳台') return _hongKongMacauTaiwanTerms;
    if (category == '国际') {
      return const [
        '国际',
        'international',
        'general',
        'legislative',
        'religious',
        ' tv',
        'rai ',
        'rtl ',
        'fox ',
        'ion ',
        'cnn',
        'bbc',
        'nhk',
        'kbs',
      ];
    }
    if (category == '广播') {
      return const ['广播', '电台', 'radio', 'fm ', 'am '];
    }
    if (category == '数字') return _digitalTerms;
    final provinceTerms = _provinceAliases[category];
    if (provinceTerms != null) return provinceTerms;
    if (category == '网络直播') {
      return const [
        ..._platformGroups,
        '咪咕直播',
        '直播中国',
        '熊猫直播',
        '游戏风云',
        '电竞',
        '购物',
        '商城',
        'shop',
        'shopping',
      ];
    }
    return null;
  }

  static Iterable<String> get allCategoryCandidateTerms sync* {
    for (final category in categories) {
      if (category == '其他') continue;
      yield* candidateTermsForCategory(category) ?? const <String>[];
    }
  }

  static String sortKeyForCategory({
    required String category,
    required String name,
    String? tvgId,
    String? groupTitle,
  }) {
    final identity = '$name ${tvgId ?? ''}'.toLowerCase();
    final naturalName = _naturalSortKey(name);
    if (category == '央视') {
      if (RegExp(r'(?:cctv|央视)\s*[-_]?\s*4k\b').hasMatch(identity)) {
        return '0800-$naturalName';
      }
      if (RegExp(r'(?:cctv|央视)\s*[-_]?\s*8k\b').hasMatch(identity)) {
        return '0801-$naturalName';
      }
      final match = RegExp(
        r'(?:cctv|央视)\s*[-_]?\s*0*(\d{1,2})',
      ).firstMatch(identity);
      if (match != null) {
        final number = int.parse(match.group(1)!);
        final isPlus =
            number == 5 &&
            (identity.contains('cctv5+') ||
                identity.contains('cctv 5+') ||
                identity.contains('体育赛事') ||
                identity.contains('sports plus'));
        final isUltraHd = identity.contains('4k') || identity.contains('8k');
        final variant = isPlus ? 2 : (isUltraHd ? 1 : 0);
        return '${number.toString().padLeft(3, '0')}-$variant-$naturalName';
      }
      if (identity.contains('cgtn')) return '0900-$naturalName';
      return '0999-$naturalName';
    }
    if (provinceCategories.contains(category)) {
      final group = (groupTitle ?? '').toLowerCase();
      final isSatellite = identity.contains('卫视') || group.contains('卫视');
      final isProvinceLevel = identity.contains(category.toLowerCase());
      final rank = isSatellite ? 0 : (isProvinceLevel ? 1 : 2);
      return '$rank-$naturalName';
    }
    return naturalName;
  }

  static String _naturalSortKey(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized.replaceAllMapped(
      RegExp(r'\d+'),
      (match) => int.parse(match.group(0)!).toString().padLeft(8, '0'),
    );
  }

  static bool isRadioChannel({
    required String name,
    String? groupTitle,
    String? tvgId,
    String? streamUrl,
  }) {
    final identity = '$name ${tvgId ?? ''}'.toLowerCase();
    final group = (groupTitle ?? '').toLowerCase();
    if (_containsAny(identity, const ['广播', '电台', 'radio'])) return true;
    if (RegExp(r'(^|\s|[-_])(?:fm|am)(?:\s|$|[-_0-9])').hasMatch(identity)) {
      return true;
    }
    final path = Uri.tryParse(streamUrl ?? '')?.path.toLowerCase() ?? '';
    if (_containsAny(path, const ['.aac', '.mp3', '.m4a', '.ogg', '.opus'])) {
      return true;
    }
    return _containsAny(group, const ['广播', '电台', 'radio']);
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
    if (_isProtectedCatalogContent(groupTitle)) return false;
    if (isPlatformLivestream(
      name: name,
      groupTitle: groupTitle,
      streamUrl: streamUrl,
    )) {
      return true;
    }
    if (_isExplicitlyExcludedCatalogContent(name, groupTitle)) return true;
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

  static bool _isExplicitlyExcludedCatalogContent(
    String name,
    String? groupTitle,
  ) {
    final normalizedName = name.trim().toLowerCase();
    final group = (groupTitle ?? '').trim().toLowerCase();
    if (group == '咪咕直播' || RegExp(r'^咪咕直播\d+$').hasMatch(normalizedName)) {
      return true;
    }
    if (group == '直播中国' ||
        normalizedName == '直播中国' ||
        normalizedName == '熊猫直播') {
      return true;
    }
    if (normalizedName.contains('游戏风云') || normalizedName.contains('电竞')) {
      return true;
    }
    if (group == 'shop' ||
        group == 'shopping' ||
        group.contains('购物') ||
        normalizedName.contains('购物') ||
        normalizedName.contains('商城')) {
      return true;
    }
    return false;
  }

  static bool _isProtectedCatalogContent(String? groupTitle) {
    final group = (groupTitle ?? '').trim().toLowerCase();
    return group == 'xxx' || group == 'github 智慧发现';
  }

  static bool _isInternationalTelevision(String name, String group) {
    if (_containsAny(group, const [
      '国际',
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
      r'(^|\s|[-_])(tv|television|channel)(\s|$|[-_0-9])|^(rai|rtl|fox|ion|cnn|bbc|nhk|kbs|mbc|sbs|abc|cbs|nbc|dw|sky)\b',
    ).hasMatch(lowerName);
  }

  static bool _containsAny(String text, List<String> values) =>
      values.any(text.contains);
}
