import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AiRuntimeValues {
  const AiRuntimeValues({
    required this.baseUrl,
    required this.model,
    required this.apiKey,
    required this.enabled,
  });

  final String baseUrl;
  final String model;
  final String apiKey;
  final bool enabled;

  bool get ready => enabled && baseUrl.isNotEmpty &&
      model.isNotEmpty && apiKey.isNotEmpty;
}

/// Public endpoint and model live in preferences. The credential stays in
/// platform secure storage and is excluded from the application's backup.
class AiRuntimeSettings {
  AiRuntimeSettings({FlutterSecureStorage? storage})
      : _storage = storage ?? (Platform.isMacOS
            ? const FlutterSecureStorage(
                mOptions: MacOsOptions(usesDataProtectionKeychain: false),
              )
            : const FlutterSecureStorage());

  static final instance = AiRuntimeSettings();
  static const _urlKey = 'bobtv_ai_base_url_v1';
  static const _modelKey = 'bobtv_ai_model_v1';
  static const _enabledKey = 'bobtv_ai_enabled_v1';
  static const _secretKey = 'bobtv_ai_api_key_v1';

  final FlutterSecureStorage _storage;

  Future<AiRuntimeValues> load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_enabledKey)) {
      final environment = Platform.environment;
      final url = (environment['OPENAI_BASE_URL'] ?? '').trim();
      final key = (environment['OPENAI_API_KEY'] ?? '').trim();
      return AiRuntimeValues(
        baseUrl: url,
        model: (environment['OPENAI_MODEL'] ?? '').trim(),
        apiKey: key,
        enabled: url.isNotEmpty && key.isNotEmpty,
      );
    }
    return AiRuntimeValues(
      baseUrl: prefs.getString(_urlKey) ?? '',
      model: prefs.getString(_modelKey) ?? '',
      apiKey: await _storage.read(key: _secretKey) ?? '',
      enabled: prefs.getBool(_enabledKey) ?? false,
    );
  }

  Future<void> save({
    required String baseUrl,
    required String model,
    required bool enabled,
    String? replacementKey,
  }) async {
    final url = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final modelName = model.trim();
    if (enabled && (!isSafeEndpoint(url) || modelName.isEmpty)) {
      throw const FormatException('Invalid AI endpoint or model');
    }
    if (replacementKey != null && replacementKey.trim().isNotEmpty) {
      await _storage.write(key: _secretKey, value: replacementKey.trim());
    }
    var storedKey = await _storage.read(key: _secretKey) ?? '';
    if (enabled && storedKey.isEmpty) {
      final environmentKey = (Platform.environment['OPENAI_API_KEY'] ?? '').trim();
      if (environmentKey.isNotEmpty) {
        await _storage.write(key: _secretKey, value: environmentKey);
        storedKey = environmentKey;
      }
    }
    if (enabled && storedKey.isEmpty) {
      throw const FormatException('An API key is required');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_urlKey, url);
    await prefs.setString(_modelKey, modelName);
    await prefs.setBool(_enabledKey, enabled);
  }

  Future<void> removeKey() => _storage.delete(key: _secretKey);

  static bool isSafeEndpoint(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) return false;
    if (uri.scheme == 'https') return true;
    return uri.scheme == 'http' &&
        const {'localhost', '127.0.0.1', '::1'}.contains(uri.host);
  }
}
