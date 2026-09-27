import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_diagnostics.dart';
import 'channel_category_classifier.dart';
import 'github_ai_crawler_service.dart';

class CountryNameInput {
  final String name;
  final String? groupTitle;

  const CountryNameInput(this.name, this.groupTitle);

  String get key => '${name.trim().toLowerCase()}\u0000'
      '${(groupTitle ?? '').trim().toLowerCase()}';
}

/// Resolves only countries that structured channel metadata cannot identify.
/// The existing crawler's OpenAI-compatible runtime settings are reused.
class ChannelCountryAiService {
  ChannelCountryAiService({OpenAiRuntimeConfig? config, Dio? dio})
      : config = config ?? OpenAiRuntimeConfig.fromEnvironment(),
        _dio = dio;

  static const _cacheKey = 'bobtv_country_ai_cache_v1';
  static const _batchSize = 20;
  static const _maximumPerLoad = 120;

  final OpenAiRuntimeConfig config;
  final Dio? _dio;
  Map<String, String>? _cache;
  bool _running = false;

  bool get enabled => config.enabled;

  Future<Map<String, String>> cachedCountries() async {
    if (_cache != null) return Map.of(_cache!);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheKey);
    try {
      final decoded = jsonDecode(raw ?? '{}');
      _cache = decoded is Map
          ? decoded.map((key, value) => MapEntry(key.toString(), value.toString()))
          : <String, String>{};
    } catch (_) {
      _cache = <String, String>{};
    }
    return Map.of(_cache!);
  }

  Future<void> classifyUnknown(
    List<CountryNameInput> inputs, {
    required void Function(Map<String, String>) onBatch,
  }) async {
    if (!enabled || _running) return;
    _running = true;
    try {
      await _classifyUnknown(inputs, onBatch: onBatch);
    } finally {
      _running = false;
    }
  }

  Future<void> _classifyUnknown(
    List<CountryNameInput> inputs, {
    required void Function(Map<String, String>) onBatch,
  }) async {
    await cachedCountries();
    final unique = <String, CountryNameInput>{};
    for (final input in inputs) {
      if ((_cache ?? const <String, String>{}).containsKey(input.key)) continue;
      unique.putIfAbsent(input.key, () => input);
      if (unique.length >= _maximumPerLoad) break;
    }
    final pending = unique.values.toList();
    if (pending.isEmpty) return;

    final client = _dio ?? Dio(BaseOptions(
      baseUrl: config.baseUrl.endsWith('/')
          ? config.baseUrl.substring(0, config.baseUrl.length - 1)
          : config.baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 45),
      headers: {
        'Authorization': 'Bearer ${config.apiKey}',
        'Content-Type': 'application/json',
      },
    ));
    try {
      for (var start = 0; start < pending.length; start += _batchSize) {
        final batch = pending.skip(start).take(_batchSize).toList();
        final additions = <String, String>{};
        try {
          final response = await client.post<Map<String, dynamic>>(
            '/chat/completions',
            data: {
              'model': config.model,
              'messages': [
                {
                  'role': 'system',
                  'content': '根据电视频道名称和来源分组判断所属国家或地区。'
                      '只根据可靠的台名线索判断，不根据语言、节目类型或网址猜测。'
                      '不确定时返回“未识别地区”。逐项返回对应的 index、country 和 0 到 1 的 confidence。',
                },
                {
                  'role': 'user',
                  'content': jsonEncode([
                    for (var index = 0; index < batch.length; index++)
                      {
                        'index': index,
                        'name': batch[index].name,
                        'group': batch[index].groupTitle ?? '',
                      },
                  ]),
                },
              ],
              'response_format': {
                'type': 'json_schema',
                'json_schema': {
                  'name': 'channel_country',
                  'strict': true,
                  'schema': {
                    'type': 'object',
                    'additionalProperties': false,
                    'properties': {
                      'items': {
                        'type': 'array',
                        'items': {
                          'type': 'object',
                          'additionalProperties': false,
                          'properties': {
                            'index': {'type': 'integer'},
                            'country': {'type': 'string'},
                            'confidence': {'type': 'number'},
                          },
                          'required': ['index', 'country', 'confidence'],
                        },
                      },
                    },
                    'required': ['items'],
                  },
                },
              },
              'max_completion_tokens': 1800,
            },
          );
          final choices = response.data?['choices'];
          final message = choices is List && choices.isNotEmpty &&
                  choices.first is Map
              ? (choices.first as Map)['message']
              : null;
          final content = message is Map ? message['content'] : null;
          final decoded = jsonDecode(content?.toString() ?? '{}');
          final decisions = decoded is Map ? decoded['items'] : null;
          final allowed = ChannelCategoryClassifier.internationalCountryNames.values.toSet();
          if (decisions is List) {
            for (final decision in decisions.whereType<Map>()) {
              final index = decision['index'];
              final country = decision['country'];
              final confidence = decision['confidence'];
              if (index is! int || index < 0 || index >= batch.length) continue;
              if (country is! String || confidence is! num) continue;
              if (allowed.contains(country) && confidence >= 0.8) {
                additions[batch[index].key] = country;
              }
            }
          }
          for (final input in batch) {
            _cache![input.key] = additions[input.key] ?? '未识别地区';
          }
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_cacheKey, jsonEncode(_cache));
          if (additions.isNotEmpty) onBatch(additions);
        } catch (error, stackTrace) {
          AppDiagnostics.instance.recordError(
            'channel_country_ai', error, stackTrace,
          );
          break;
        }
      }
    } finally {
      if (_dio == null) client.close();
    }
  }
}
