import 'country_names.dart';

/// Initials for the finite country-name vocabulary in CountryNames.
/// This is navigation metadata, not a general Chinese transliterator.
class CountryNameIndex {
  CountryNameIndex._();

  static const _initials = {
    'A': '阿安奥澳埃爱',
    'B': '巴波伯博白比玻保百不布北冰贝',
    'C': '朝赤',
    'D': '丹多大德迪东',
    'E': '厄俄',
    'F': '法斐福佛芬菲梵',
    'G': '哥格根刚冈古瓜圭关',
    'H': '海荷赫洪哈黑韩',
    'J': '加吉几基柬捷津',
    'K': '科库克肯喀卡开',
    'L': '老黎莱利立列卢拉罗留联',
    'M': '马美毛摩密孟蒙墨缅莫秘',
    'N': '南尼纳挪诺瑙纽',
    'O': '欧',
    'P': '葡皮帕',
    'R': '日瑞',
    'S': '斯苏塞索所圣沙萨',
    'T': '台泰坦汤塔特土突托图',
    'W': '瓦文委危乌伪未',
    'X': '新西希香休叙匈象',
    'Y': '亚牙也越以伊意印英约',
    'Z': '中智直泽乍赞',
  };

  static String initial(String label) {
    final name = label.trim();
    if (name.isEmpty || name == '未识别地区') return '#';
    // The country name is pronounced bì lǔ.
    if (name == '秘鲁' || name == '秘魯') return 'B';
    final first = String.fromCharCode(name.runes.first).toUpperCase();
    if (RegExp(r'^[A-Z]$').hasMatch(first)) return first;
    for (final entry in _initials.entries) {
      if (entry.value.contains(first)) return entry.key;
    }
    return '#';
  }

  static bool matches(String label, String query) {
    final term = query.trim().toLowerCase();
    if (term.isEmpty) return true;
    if (label.toLowerCase().contains(term)) return true;
    if (term.length == 1 && initial(label).toLowerCase() == term) return true;
    return CountryNames.normalize(
      label,
    ).toLowerCase().contains(CountryNames.normalize(term).toLowerCase());
  }

  static int compareInitials(String a, String b) => a == b
      ? 0
      : a == '#'
      ? 1
      : b == '#'
      ? -1
      : a.compareTo(b);
}
