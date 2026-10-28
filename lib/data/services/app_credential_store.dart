import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Background access must never raise a system authorization dialog. A failed
/// access stays paused across restarts until an explicit settings action.
class CredentialAccessPaused implements Exception {
  const CredentialAccessPaused();
}

class AppCredentialStore {
  AppCredentialStore(this.scope, {FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage(),
      _native = Platform.isMacOS && storage == null;

  final String scope;
  final FlutterSecureStorage _storage;
  final bool _native;
  static const channel = MethodChannel('com.briconbric.bobtv/credentials');
  String get _pauseKey => 'bobtv_credential_paused_v1_$scope';

  Future<bool> get paused async =>
      (await SharedPreferences.getInstance()).getBool(_pauseKey) ?? false;

  Future<T?> _call<T>(
    String operation,
    String key,
    String? value,
    bool interactive,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    if (!interactive && (prefs.getBool(_pauseKey) ?? false)) {
      throw const CredentialAccessPaused();
    }
    try {
      final T? result;
      if (_native) {
        result = await channel.invokeMethod<T>(operation, {
          'key': key,
          'value': value,
          'interactive': interactive,
        });
      } else {
        switch (operation) {
          case 'read':
            result = await _storage.read(key: key) as T?;
          case 'write':
            await _storage.write(key: key, value: value);
            result = null;
          default:
            await _storage.delete(key: key);
            result = null;
        }
      }
      if (interactive) await prefs.remove(_pauseKey);
      return result;
    } on PlatformException {
      await prefs.setBool(_pauseKey, true);
      throw const CredentialAccessPaused();
    }
  }

  Future<String?> read(String key, {bool interactive = false}) =>
      _call<String>('read', key, null, interactive);
  Future<void> write(
    String key,
    String value, {
    bool interactive = false,
  }) async {
    await _call<void>('write', key, value, interactive);
  }

  Future<void> delete(String key, {bool interactive = false}) async {
    await _call<void>('delete', key, null, interactive);
  }
}
