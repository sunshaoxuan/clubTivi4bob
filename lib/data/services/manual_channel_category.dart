import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'channel_category_classifier.dart';

class ChannelCategoryDestination {
  ChannelCategoryDestination(List<String> path)
    : _safeInput = path.every((name) => nameError(name) == null),
      path = List.unmodifiable([
        for (var index = 0; index < path.length; index++)
          index == 0
              ? ChannelCategoryClassifier.normalizeCountryName(path[index])
              : normalizeName(path[index]),
      ]);
  final List<String> path;
  final bool _safeInput;

  static const maxDepth = 6;
  static const maxNameLength = 48;

  static String normalizeName(String name) =>
      name.trim().replaceAll(RegExp(r' +'), ' ');

  static String? nameError(String name) {
    if (RegExp(
      r'[\x00-\x1f\x7f/\\\u200b-\u200f\u202a-\u202e\u2060-\u206f]',
    ).hasMatch(name)) {
      return '名称不能包含斜杠、换行或隐藏控制字符';
    }
    final normalized = normalizeName(name);
    if (normalized.isEmpty) return '请输入名称';
    if (normalized.runes.length > maxNameLength) return '名称最多 48 个字';
    if (normalized == '全部' ||
        normalized == '全部地区' ||
        normalized.toLowerCase() == 'favorites' ||
        normalized.toLowerCase().startsWith('fav:')) {
      return '请使用具体的分类名称';
    }
    return null;
  }

  static List<String> get countries => [
    '中国',
    '其他',
    ...(ChannelCategoryClassifier.internationalCountryNames.values
        .toSet()
        .toList()
      ..sort()),
    '未识别地区',
  ];

  /// Suggestions include the catalog and locally pending edits. They are not
  /// a whitelist: an explicit user choice can introduce a new hierarchy.
  static List<String> children(
    List<String> path, {
    Iterable<ChannelCategoryDestination> existing = const [],
  }) {
    final mediaLevel = path.length > 1 && path[1] == '电视' ? 1 : 0;
    if (path.length >= maxDepth + mediaLevel) return [];
    final suggestions = <String>[];
    if (path.isEmpty) suggestions.addAll(countries);
    if (path.length == 1) {
      suggestions.addAll(
        path.first == '中国'
            ? ['央视', '地方', '数字', '广播']
            : path.first == '其他'
            ? ['待识别', '电视', '广播']
            : ['电视', '广播'],
      );
    }
    if (path.length == 2 &&
        path.first != '中国' &&
        path.first != '其他' &&
        path[1] == '电视') {
      suggestions.addAll(ChannelCategoryClassifier.internationalGenres);
    }
    if (path.length == 2 && path.first == '中国' && path[1] == '地方') {
      suggestions.addAll(ChannelCategoryClassifier.provinceCategories);
    }
    for (final destination in existing) {
      if (!destination.valid || destination.path.length <= path.length) {
        continue;
      }
      if (path.asMap().entries.every(
        (entry) => destination.path[entry.key] == entry.value,
      )) {
        suggestions.add(destination.path[path.length]);
      }
    }
    final seen = <String>{};
    return suggestions.where((name) => seen.add(name.toLowerCase())).toList();
  }

  static ChannelCategoryDestination? fromGroup(String? group) {
    final parts = (group ?? '').split(' / ');
    if (parts.length < 2 && parts.first != '其他') return null;
    List<String> path;
    if (parts.length >= 2 && parts.first == '中国' && parts[1] == '其他') {
      path = ['其他', '待识别', ...parts.skip(2)];
    } else if (parts.first == '中国') {
      path = [
        '中国',
        if (ChannelCategoryClassifier.provinceCategories.contains(parts[1]))
          '地方',
        ...parts.skip(1),
      ];
    } else if (parts.first == '其他') {
      path = parts;
    } else if (parts.first == '国际' && parts[1] != '中国') {
      path = parts.skip(1).toList();
    } else {
      return null;
    }
    final destination = ChannelCategoryDestination(path);
    return destination.valid ? destination : null;
  }

  static List<String> navigationCategories(
    Iterable<ChannelCategoryDestination> existing,
  ) {
    final custom =
        existing
            .where((d) => d.valid && d.country == '中国')
            .map((d) => d.category)
            .toSet()
            .difference(ChannelCategoryClassifier.categories.toSet())
            .toList()
          ..sort();
    return [...ChannelCategoryClassifier.categories, ...custom];
  }

  bool get valid {
    if (!_safeInput ||
        path.isEmpty ||
        path.length > maxDepth + (path.length > 1 && path[1] == '电视' ? 1 : 0) ||
        path.first == '国际') {
      return false;
    }
    if (path.first == '中国' &&
        (path.length < 2 || (path[1] == '地方' && path.length < 3))) {
      return false;
    }
    if (path.first == '中国' && path[1] == '国际') return false;
    return group.runes.length <= 192;
  }

  List<String> get _chinaPath =>
      path.length >= 3 &&
          path[1] == '地方' &&
          ChannelCategoryClassifier.provinceCategories.contains(path[2])
      ? path.skip(2).toList()
      : path.skip(1).toList();
  String get category => path.first == '其他'
      ? '其他'
      : path.first == '中国'
      ? (ChannelCategoryClassifier.provinceCategories.contains(_chinaPath.first)
            ? _chinaPath.first
            : _chinaPath.join(' / '))
      : '国际';
  String get country => path.first == '其他' ? '未识别地区' : path.first;
  String get group => path.first == '其他'
      ? path.join(' / ')
      : path.first == '中国'
      ? '中国 / ${_chinaPath.join(' / ')}'
      : '国际 / ${path.join(' / ')}';
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
