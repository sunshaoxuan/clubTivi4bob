import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'channel_category_classifier.dart';

class ChannelCategoryDestination {
  ChannelCategoryDestination(List<String> path)
    : path = List.unmodifiable(path);
  final List<String> path;

  static List<String> get countries => [
    '中国',
    ...(ChannelCategoryClassifier.internationalCountryNames.values
        .toSet()
        .toList()
      ..sort()),
    '未识别地区',
  ];

  static List<String> children(List<String> path) {
    if (path.isEmpty) return countries;
    if (path.length == 1) {
      return path.first == '中国'
          ? ['央视', '地方', '数字', '广播', '其他']
          : ChannelCategoryClassifier.internationalGenres;
    }
    if (path.length == 2 && path.first == '中国' && path[1] == '地方') {
      return ChannelCategoryClassifier.provinceCategories;
    }
    return [];
  }

  bool get valid {
    if (path.isEmpty) return false;
    for (var depth = 0; depth < path.length; depth++) {
      if (!children(path.take(depth).toList()).contains(path[depth])) {
        return false;
      }
    }
    return path.first != '中国' ||
        (path.length == 2 && path[1] != '地方') ||
        path.length == 3;
  }

  String get category => path.first == '中国' ? path.last : '国际';
  String get country => path.first;
  String get group =>
      path.first == '中国' ? '中国 / ${path.last}' : '国际 / ${path.join(' / ')}';
}

/// Route URLs survive provider refreshes and website channel-ID replacements.
/// Every known alternative of the selected channel receives the same choice.
class ManualChannelCategory {
  static const preferenceKey = 'bobtv_manual_route_categories_v1';

  static Future<Map<String, ChannelCategoryDestination>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final decoded = jsonDecode(prefs.getString(preferenceKey) ?? '{}');
      if (decoded is! Map) return {};
      final result = <String, ChannelCategoryDestination>{};
      for (final entry in decoded.entries) {
        if (entry.key is! String ||
            entry.key.isEmpty ||
            entry.value is! List ||
            !(entry.value as List).every((value) => value is String)) {
          continue;
        }
        final destination = ChannelCategoryDestination(
          (entry.value as List).cast<String>(),
        );
        if (destination.valid) result[entry.key as String] = destination;
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(
    Iterable<String> urls,
    ChannelCategoryDestination destination,
  ) async {
    if (!destination.valid) throw ArgumentError('Invalid channel category');
    final current = await load();
    for (final url in urls.where((url) => url.isNotEmpty)) {
      current[url] = destination;
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      preferenceKey,
      jsonEncode({
        for (final entry in current.entries) entry.key: entry.value.path,
      }),
    )) {
      throw StateError('Could not save channel category');
    }
  }

  static Future<void> remove(Iterable<String> urls) async {
    final current = await load();
    for (final url in urls) {
      current.remove(url);
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      preferenceKey,
      jsonEncode({for (final e in current.entries) e.key: e.value.path}),
    )) {
      throw StateError('Could not reconcile channel categories');
    }
  }
}
