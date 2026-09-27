import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_diagnostics.dart';
import 'ai_runtime_settings.dart';
import 'channel_category_classifier.dart';

class CategoryNameInput {
  const CategoryNameInput({
    required this.id,
    required this.name,
    this.groupTitle,
    this.tvgId,
  });

  final String id;
  final String name;
  final String? groupTitle;
  final String? tvgId;

  String get key => '$id\u0000${name.trim().toLowerCase()}\u0000'
      '${(groupTitle ?? '').trim().toLowerCase()}\u0000'
      '${(tvgId ?? '').trim().toLowerCase()}';
}

/// AI only supplements conservative deterministic classification. A missing
/// configuration, request failure or low confidence never changes a category.
class ChannelCategoryAiService {
  ChannelCategoryAiService({Dio? dio, AiRuntimeValues? settings})
      : _dio = dio,
        _settings = settings;

  static const _cacheKey = 'bobtv_category_ai_cache_v1';
  static const _batchSize = 20;
  static const _maximumPerLoad = 120;

  final Dio? _dio;
  final AiRuntimeValues? _settings;
  Map<String, String>? _cache;
  bool _running = false;

  Future<Map<String, String>> cachedCategories() async {
    if (_cache != null) return Map.of(_cache!);
    final prefs = await SharedPreferences.getInstance();
    try {
      final decoded = jsonDecode(prefs.getString(_cacheKey) ?? '{}');
      _cache = decoded is Map
          ? {
              for (final entry in decoded.entries)
                if (entry.key is String && entry.value is String &&
                    ChannelCategoryClassifier.categories.contains(entry.value))
                  entry.key as String: entry.value as String,
            }
          : <String, String>{};
    } catch (_) {
      _cache = <String, String>{};
    }
    return Map.of(_cache!);
  }

  Future<void> classifyUnknown(
    List<CategoryNameInput> inputs, {
    required void Function(Map<String, String>) onBatch,
  }) async {
    if (_running) return;
    final settings = _settings ?? await AiRuntimeSettings.instance.load();
    if (!settings.ready) return;
    _running = true;
    try {
      await cachedCategories();
      final unique = <String, CategoryNameInput>{};
      for (final input in inputs) {
        if (_cache!.containsKey(input.key)) continue;
        unique.putIfAbsent(input.key, () => input);
        if (unique.length >= _maximumPerLoad) break;
      }
      final pending = unique.values.toList();
      if (pending.isEmpty) return;
      final client = _dio ?? Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 45),
        followRedirects: false,
        headers: {'Authorization': 'Bearer ${settings.apiKey}'},
      ));
      try {
        for (var start = 0; start < pending.length; start += _batchSize) {
          final batch = pending.skip(start).take(_batchSize).toList();
          try {
            final response = await client.post<Map<String, dynamic>>(
              '${settings.baseUrl}/chat/completions',
              data: {
                'model': settings.model,
                'messages': [
                  {
                    'role': 'system',
                    'content': '根据电视频道台名、来源分组和节目单标识判断中国省份'
                        '或国际地区。只依据明确可靠的地理线索，不根据字母片段、'
                        '语言、节目类型或网址猜测。NRBTV 不等于 BTV。'
                        '无法确定时返回“其他”。仅返回 JSON 对象，格式为'
                        '{"items":[{"index":0,"category":"其他",'
                        '"confidence":0.0}]}。',
                  },
                  {
                    'role': 'user',
                    'content': jsonEncode([
                      for (var index = 0; index < batch.length; index++)
                        {
                          'index': index,
                          'name': batch[index].name,
                          'group': batch[index].groupTitle ?? '',
                          'tvgId': batch[index].tvgId ?? '',
                        },
                    ]),
                  },
                ],
                'max_completion_tokens': 1800,
              },
            );
            final choices = response.data?['choices'];
            final message = choices is List && choices.isNotEmpty &&
                    choices.first is Map
                ? (choices.first as Map)['message'] : null;
            final content = message is Map ? message['content'] : null;
            final parsed = jsonDecode(content?.toString() ?? '{}');
            final items = parsed is Map ? parsed['items'] : null;
            if (items is! List) throw const FormatException('Invalid AI result');
            final additions = <String, String>{};
            for (final item in items.whereType<Map>()) {
              final index = item['index'];
              final category = item['category'];
              final confidence = item['confidence'];
              if (index is! int || index < 0 || index >= batch.length ||
                  category is! String || confidence is! num ||
                  confidence < 0.9 || category == '其他' ||
                  !ChannelCategoryClassifier.categories.contains(category)) {
                continue;
              }
              additions[batch[index].key] = category;
            }
            if (additions.isNotEmpty) {
              _cache!.addAll(additions);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString(_cacheKey, jsonEncode(_cache));
              onBatch(additions);
            }
          } catch (error, stackTrace) {
            AppDiagnostics.instance.recordError(
              'channel_category_ai',
              StateError('AI classification failed'),
              stackTrace,
            );
            break;
          }
        }
      } finally {
        if (_dio == null) client.close();
      }
    } finally {
      _running = false;
    }
  }
}
