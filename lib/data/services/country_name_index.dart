import 'country_names.dart';
import 'country_collation_data.dart';

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

  static String initial(String label, {String locale = 'zh-CN'}) {
    final name = label.trim();
    final indexed = countryLocaleCollation[locale]?[name];
    if (indexed != null) return indexed.$2;
    if (name.isEmpty || name == '未识别地区') return '#';
    // The country name is pronounced bì lǔ.
    if (locale == 'zh-CN' && (name == '秘鲁' || name == '秘魯')) return 'B';
    final first = String.fromCharCode(name.runes.first).toUpperCase();
    if (RegExp(r'^[A-Z]$').hasMatch(first)) return first;
    if (locale != 'zh-CN') {
      final folded = searchKey(first).toUpperCase();
      return RegExp(r'^[A-Z]').hasMatch(folded) ? folded[0] : '#';
    }
    for (final entry in _initials.entries) {
      if (entry.value.contains(first)) return entry.key;
    }
    return '#';
  }

  static String searchKey(String text) => text.runes
      .map(
        (rune) =>
            countrySearchFolds[String.fromCharCode(rune)] ??
            String.fromCharCode(rune),
      )
      .join()
      .replaceAll(RegExp(r'[\u0300-\u036f]'), '')
      .toLowerCase();

  static bool matches(String label, String query, {String locale = 'zh-CN'}) {
    final term = query.trim().toLowerCase();
    if (term.isEmpty) return true;
    if (searchKey(label).contains(searchKey(term))) return true;
    if (term.length == 1 &&
        initial(label, locale: locale).toLowerCase() == term) {
      return true;
    }
    final canonical = countryLocaleCollation[locale]?[label]?.$3 ?? label;
    return CountryNames.normalize(
      canonical,
    ).toLowerCase().contains(CountryNames.normalize(term).toLowerCase());
  }

  static int compare(String a, String b, {String locale = 'zh-CN'}) {
    final left = countryLocaleCollation[locale]?[a];
    final right = countryLocaleCollation[locale]?[b];
    if (left != null && right != null) return left.$1.compareTo(right.$1);
    final groups = compareInitials(
      initial(a, locale: locale),
      initial(b, locale: locale),
    );
    return groups != 0 ? groups : searchKey(a).compareTo(searchKey(b));
  }

  static int compareInitials(String a, String b) => a == b
      ? 0
      : a == '#'
      ? 1
      : b == '#'
      ? -1
      : int.tryParse(a.replaceFirst('畫', '')) != null &&
            int.tryParse(b.replaceFirst('畫', '')) != null
      ? int.parse(
          a.replaceFirst('畫', ''),
        ).compareTo(int.parse(b.replaceFirst('畫', '')))
      : a.compareTo(b);
}
