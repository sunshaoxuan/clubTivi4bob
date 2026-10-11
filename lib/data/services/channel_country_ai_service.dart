import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_diagnostics.dart';
import 'server_task_client.dart';
import 'channel_category_classifier.dart';

class CountryNameInput {
  final String name;
  final String? groupTitle;

  const CountryNameInput(this.name, this.groupTitle);

  String get key =>
      '${name.trim().toLowerCase()}\u0000'
      '${(groupTitle ?? '').trim().toLowerCase()}';
}

/// Resolves only countries that structured channel metadata cannot identify.
/// The existing crawler's OpenAI-compatible runtime settings are reused.
class ChannelCountryAiService {
  ChannelCountryAiService({Object? config, Dio? dio}) : _dio = dio;

  static const _cacheKey = 'bobtv_country_ai_cache_v1';
  static const _batchSize = 20;
  static const _maximumPerLoad = 120;

  final Dio? _dio;
  Map<String, String>? _cache;
  bool _running = false;

  bool _enabled = false;
  bool get enabled => _enabled;
  Future<bool> isEnabled() async {
    _enabled = (await SharedPreferences.getInstance()).getBool('bobtv_ai_enabled_v1') == true;
    return _enabled;
  }

  Future<Map<String, String>> cachedCountries() async {
    if (_cache != null) return Map.of(_cache!);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheKey);
    try {
      final decoded = jsonDecode(raw ?? '{}');
      _cache = decoded is Map
          ? decoded.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
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
    if (_running || !await isEnabled()) return;
    _running = true;
    try {
      await cachedCountries();
      final pending = {
        for (final input in inputs)
          if (!_cache!.containsKey(input.key)) input.key: input,
      }.values.take(_maximumPerLoad).toList();
      for (var start = 0; start < pending.length; start += _batchSize) {
        final batch = pending.skip(start).take(_batchSize).toList();
        final response = await ServerTaskClient(dio: _dio).classify('country', [
          for (final input in batch)
            {'name': input.name, 'group': input.groupTitle ?? ''},
        ]);
        final additions = <String, String>{};
        for (final item
            in (response['items'] as List? ?? []).whereType<Map>()) {
          final index = item['index'],
              country = item['country'],
              confidence = item['confidence'];
          if (index is int &&
              index >= 0 &&
              index < batch.length &&
              country is String &&
              confidence is num &&
              confidence >= .8 &&
              ChannelCategoryClassifier.internationalCountryNames.containsValue(
                country,
              )) {
            additions[batch[index].key] = country;
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
        'server_country_lookup',
        StateError('Server classification unavailable'),
        stack,
      );
    } finally {
      _running = false;
    }
  }
}
