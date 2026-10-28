import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_credential_store.dart';

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

  bool get ready =>
      enabled && baseUrl.isNotEmpty && model.isNotEmpty && apiKey.isNotEmpty;
}

/// Public endpoint and model live in preferences. The credential stays in
/// platform secure storage and is excluded from the application's backup.
class AiRuntimeSettings {
  AiRuntimeSettings({FlutterSecureStorage? storage})
    : _storage = AppCredentialStore('ai', storage: storage);

  static final instance = AiRuntimeSettings();
  static const _urlKey = 'bobtv_ai_base_url_v1';
  static const _modelKey = 'bobtv_ai_model_v1';
  static const _enabledKey = 'bobtv_ai_enabled_v1';
  static const _secretKey = 'bobtv_ai_api_key_v1';

  final AppCredentialStore _storage;

  Future<AiRuntimeValues> load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_enabledKey)) {
      final environment = Platform.environment;
      final url = (environment['OPENAI_BASE_URL'] ?? '').trim();
      final key = (environment['OPENAI_API_KEY'] ?? '').trim();
      return AiRuntimeValues(
        baseUrl: url,
        model: (environment['OPENAI_MODEL'] ?? 'gpt-5.6-luna').trim(),
        apiKey: key,
        enabled: url.isNotEmpty && key.isNotEmpty,
      );
    }
    return AiRuntimeValues(
      baseUrl: prefs.getString(_urlKey) ?? '',
      model: prefs.getString(_modelKey) ?? '',
      apiKey: (prefs.getBool(_enabledKey) ?? false) ? await _readKey() : '',
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
    if (enabled) {
      if (replacementKey != null && replacementKey.trim().isNotEmpty) {
        await _storage.write(
          _secretKey,
          replacementKey.trim(),
          interactive: true,
        );
      }
      var storedKey = await _storage.read(_secretKey, interactive: true) ?? '';
      if (storedKey.isEmpty) {
        final environmentKey = (Platform.environment['OPENAI_API_KEY'] ?? '')
            .trim();
        if (environmentKey.isNotEmpty) {
          await _storage.write(_secretKey, environmentKey, interactive: true);
          storedKey = environmentKey;
        }
      }
      if (storedKey.isEmpty) {
        throw const FormatException('An API key is required');
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_urlKey, url);
    await prefs.setString(_modelKey, modelName);
    await prefs.setBool(_enabledKey, enabled);
  }

  Future<String> _readKey() async {
    try {
      return await _storage.read(_secretKey) ?? '';
    } on CredentialAccessPaused {
      return '';
    }
  }

  Future<void> authorize() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_enabledKey) ?? false)) return;
    final key = await _storage.read(_secretKey, interactive: true);
    if (key == null || key.isEmpty) {
      throw const FormatException('An API key is required');
    }
  }

  Future<void> removeKey() => _storage.delete(_secretKey, interactive: true);

  static bool isSafeEndpoint(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return false;
    }
    if (uri.scheme == 'https') return true;
    return uri.scheme == 'http' &&
        const {'localhost', '127.0.0.1', '::1'}.contains(uri.host);
  }
}
