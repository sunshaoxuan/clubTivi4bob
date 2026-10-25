import 'dart:math';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'client_fingerprint_service.dart';
import 'app_credential_store.dart';

class DeviceFavoritesCredential {
  const DeviceFavoritesCredential({
    required this.fingerprint,
    required this.token,
  });
  final String fingerprint;
  final String token;
  String get localOwner =>
      sha256.convert(utf8.encode('$fingerprint|$token')).toString();
}

/// Device-scoped secret stays in the OS credential store. It is excluded from
/// preference/database exports and release packages. Never fall back to a public
/// fingerprint or a plaintext preference when credential storage is unavailable.
class DeviceFavoritesIdentity {
  DeviceFavoritesIdentity({
    FlutterSecureStorage? storage,
    Future<String?> Function()? fingerprintLoader,
  }) : storage = AppCredentialStore('favorites', storage: storage),
       fingerprintLoader = fingerprintLoader ?? _fingerprint;
  final AppCredentialStore storage;
  final Future<String?> Function() fingerprintLoader;
  Future<DeviceFavoritesCredential?>? _loading;
  DeviceFavoritesCredential? _saved;
  static final tokenFormat = RegExp(r'^btvf1_[a-f0-9]{64}$');
  static Future<String?> _fingerprint() async {
    await ClientFingerprintService.instance.initialize();
    return ClientFingerprintService.instance.apiFingerprint;
  }

  Future<DeviceFavoritesCredential?> load() async {
    if (_saved != null) return _saved;
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  /// Called only by the user's authorization action in settings.
  Future<DeviceFavoritesCredential?> authorize() => _load(interactive: true);

  Future<DeviceFavoritesCredential?> _load({bool interactive = false}) async {
    final fingerprint = await fingerprintLoader();
    if (fingerprint == null) return null;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint)) {
      throw const FormatException('Invalid private device fingerprint');
    }
    final key = 'bobtv_private_favorites_v1_$fingerprint';
    var token = await storage.read(key, interactive: interactive);
    if (token == null) {
      final random = Random.secure();
      token =
          'btvf1_${List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
      await storage.write(key, token, interactive: interactive);
      // Confirm persistence before claiming that this device can recover it.
      if (await storage.read(key, interactive: interactive) != token) {
        throw StateError('Private favorite credential was not saved');
      }
    }
    if (!tokenFormat.hasMatch(token)) {
      throw const FormatException('Invalid private favorite credential');
    }
    return _saved = DeviceFavoritesCredential(
      fingerprint: fingerprint,
      token: token,
    );
  }
}
