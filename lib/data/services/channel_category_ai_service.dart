import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_diagnostics.dart';
import 'ai_runtime_settings.dart';
import 'server_task_client.dart';
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

  String get key =>
      '$id\u0000${name.trim().toLowerCase()}\u0000'
      '${(groupTitle ?? '').trim().toLowerCase()}\u0000'
      '${(tvgId ?? '').trim().toLowerCase()}';
}

/// AI only supplements conservative deterministic classification. A missing
/// configuration, request failure or low confidence never changes a category.
class ChannelCategoryAiService {
  ChannelCategoryAiService({Dio? dio, AiRuntimeValues? settings}) : _dio = dio;

  static const _cacheKey = 'bobtv_category_ai_cache_v1';
  static const _batchSize = 20;
  static const _maximumPerLoad = 120;

  final Dio? _dio;
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
                if (entry.key is String &&
                    entry.value is String &&
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
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('bobtv_ai_enabled_v1') != true) return;
    _running = true;
    try {
      await cachedCategories();
      final pending = {
        for (final input in inputs)
          if (!_cache!.containsKey(input.key)) input.key: input,
      }.values.take(_maximumPerLoad).toList();
      for (var start = 0; start < pending.length; start += _batchSize) {
        final batch = pending.skip(start).take(_batchSize).toList();
        final response = await ServerTaskClient(dio: _dio).classify(
          'category',
          [
            for (final input in batch)
              {
                'name': input.name,
                'group': input.groupTitle ?? '',
                'tvgId': input.tvgId ?? '',
              },
          ],
        );
        final additions = <String, String>{};
        for (final item
            in (response['items'] as List? ?? []).whereType<Map>()) {
          final index = item['index'],
              category = item['category'],
              confidence = item['confidence'];
          if (index is int &&
              index >= 0 &&
              index < batch.length &&
              category is String &&
              confidence is num &&
              confidence >= .9 &&
              category != '其他' &&
              ChannelCategoryClassifier.categories.contains(category)) {
            additions[batch[index].key] = category;
          }
        }
        if (additions.isNotEmpty) {
          _cache!.addAll(additions);
          await (await SharedPreferences.getInstance()).setString(
            _cacheKey,
            jsonEncode(_cache),
          );
          onBatch(additions);
        }
      }
    } catch (_, stack) {
      AppDiagnostics.instance.recordError(
        'server_category_lookup',
        StateError('Server classification unavailable'),
        stack,
      );
    } finally {
      _running = false;
    }
  }
}
