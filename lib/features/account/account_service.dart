import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:local_auth/local_auth.dart';
import 'package:url_launcher/url_launcher.dart';

/// Optional account state shared by desktop, mobile and TV. No player gate is
/// enabled. Future protected services must enforce authorization on the server.
class AccountService extends ChangeNotifier with WidgetsBindingObserver {
  AccountService({
    http.Client? client,
    FlutterSecureStorage? storage,
    LocalAuthentication? localAuth,
    String? origin,
  }) : _client = client ?? http.Client(),
       _storage = storage ?? credentialStorage,
       _localAuth = localAuth ?? LocalAuthentication(),
       origin = origin ?? 'https://bobtv.briconbric.com' {
    WidgetsBinding.instance.addObserver(this);
  }
  static final instance = AccountService();
  // Existing macOS releases use Developer ID distribution without a keychain
  // provisioning profile. The encrypted login keychain supports that model.
  static const credentialStorage = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  final http.Client _client;
  final FlutterSecureStorage _storage;
  final LocalAuthentication _localAuth;
  final String origin;
  static const tokenKey = 'bobtv.account.session.v1';
  static const biometricKey = 'bobtv.account.biometric.v1';
  Map<String, dynamic>? user;
  String? _token;
  bool biometric = false;
  bool locked = false;
  bool ready = false;
  Future<void>? _initializing;
  int _generation = 0;
  Future<void> _storageWork = Future<void>.value();

  Future<void> _withStorage(Future<void> Function() action) {
    final next = _storageWork.then((_) => action());
    _storageWork = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _client.close();
    super.dispose();
  }

  bool get loggedIn => user != null && _token != null && !locked;
  bool get supportsBiometrics => Platform.isIOS || Platform.isAndroid;

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    try {
      biometric =
          supportsBiometrics && await _storage.read(key: biometricKey) == 'on';
      if (biometric) {
        locked = true;
      } else {
        _token = await _storage.read(key: tokenKey);
        if (_token != null) await refresh();
      }
    } catch (_) {
      // Storage/network failures do not interrupt television playback. An
      // unreadable stored credential never becomes an authenticated session.
      _token = null;
      user = null;
    } finally {
      ready = true;
      notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && biometric && !locked) {
      _generation++;
      locked = true;
      _token = null;
      user = null;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? data,
    bool authenticated = false,
  }) async {
    if (authenticated && (!loggedIn && path != 'me')) {
      throw const AccountException('login_required');
    }
    if (authenticated && (_token == null || locked)) {
      throw const AccountException('login_required');
    }
    final requestGeneration = _generation;
    final uri = Uri.parse('$origin/api/v1/account/$path');
    final req = http.Request(method, uri)..followRedirects = false;
    req.headers['Accept'] = 'application/json';
    req.headers['User-Agent'] = 'BobTV/1.0';
    if (data != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(data);
    }
    if (authenticated) req.headers['Authorization'] = 'Bearer $_token';
    final response = await _client
        .send(req)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 25));
    Map<String, dynamic> value;
    try {
      value = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw const AccountException('service_unavailable');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = value['detail'];
      if (authenticated &&
          response.statusCode == 401 &&
          requestGeneration == _generation) {
        await clearLocal();
      }
      throw AccountException(detail is String ? detail : 'request_failed');
    }
    return value;
  }

  Future<void> refresh() async {
    final generation = _generation;
    final value = await request('me', authenticated: true);
    if (generation != _generation) return;
    user = value;
    notifyListeners();
  }

  Future<void> _accept(Map<String, dynamic> value, int generation) =>
      _withStorage(() async {
        if (generation != _generation) {
          throw const AccountException('login_cancelled');
        }
        final token = value['token'] as String;
        await _storage.write(key: tokenKey, value: token);
        if (generation != _generation) {
          await _storage.delete(key: tokenKey);
          throw const AccountException('login_cancelled');
        }
        _token = token;
        user = value['user'] as Map<String, dynamic>;
        locked = false;
        notifyListeners();
      });

  Future<void> sendCode(String email) async {
    await request('email/code', method: 'POST', data: {'email': email.trim()});
  }

  Future<void> signInEmail(String email, String code) async {
    final generation = ++_generation;
    final value = await request(
      'email/verify',
      method: 'POST',
      data: {'email': email.trim(), 'code': code.trim()},
    );
    await _accept(value, generation);
  }

  void cancelSignIn() {
    _generation++;
  }

  Future<void> signInProvider(
    String provider, {
    ValueChanged<Uri>? onAuthorization,
    bool openBrowser = true,
  }) async {
    final generation = ++_generation;
    final random = Random.secure();
    final proof = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    final challenge = base64UrlEncode(
      sha256.convert(utf8.encode(proof)).bytes,
    ).replaceAll('=', '');
    final start = await request(
      'oauth/start',
      method: 'POST',
      data: {'provider': provider, 'proof': challenge},
    );
    final authorization = Uri.parse(start['url'] as String);
    if (generation != _generation) {
      throw const AccountException('login_cancelled');
    }
    onAuthorization?.call(authorization);
    if (openBrowser) {
      var launched = false;
      try {
        launched = await launchUrl(
          authorization,
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        /* A paired phone can open the displayed authorization QR. */
      }
      if (!launched && onAuthorization == null) {
        throw const AccountException('browser_unavailable');
      }
    }
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      if (generation != _generation) {
        throw const AccountException('login_cancelled');
      }
      final result = await request(
        'oauth/poll',
        method: 'POST',
        data: {'ticket': start['ticket'], 'proof': proof},
      );
      if (result['pending'] != true) {
        await _accept(result, generation);
        return;
      }
    }
    throw const AccountException('login_expired');
  }

  Future<bool> canUseBiometrics() async {
    if (!supportsBiometrics) return false;
    try {
      return await _localAuth.canCheckBiometrics &&
          (await _localAuth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> setBiometric(bool enabled, String reason) async {
    if (!loggedIn) throw const AccountException('login_required');
    final generation = _generation;
    if (!await canUseBiometrics()) {
      throw const AccountException('biometric_unavailable');
    }
    if (!await _localAuth.authenticate(
      localizedReason: reason,
      biometricOnly: true,
    )) {
      throw const AccountException('biometric_cancelled');
    }
    // An interrupted native prompt may have locked account state on Android.
    if (locked || generation != _generation) {
      throw const AccountException('login_required');
    }
    await _withStorage(() async {
      if (locked || generation != _generation) {
        throw const AccountException('login_required');
      }
      await _storage.write(key: biometricKey, value: enabled ? 'on' : 'off');
      if (generation != _generation) return;
      biometric = enabled;
      notifyListeners();
    });
  }

  Future<void> unlock(String reason) async {
    final generation = _generation;
    if (!await _localAuth.authenticate(
      localizedReason: reason,
      biometricOnly: true,
    )) {
      throw const AccountException('biometric_cancelled');
    }
    if (generation != _generation) {
      throw const AccountException('login_cancelled');
    }
    await _storageWork;
    final token = await _storage.read(key: tokenKey);
    if (generation != _generation) return;
    _token = token;
    if (_token == null) {
      await clearLocal();
      return;
    }
    locked = false;
    try {
      await refresh();
    } catch (_) {
      if (generation == _generation) {
        _token = null;
        user = null;
        locked = biometric;
        notifyListeners();
      }
      rethrow;
    }
    notifyListeners();
  }

  Future<void> logout() async {
    // Keep the local session if revocation fails, so the user can retry.
    await request('logout', method: 'POST', authenticated: true);
    await clearLocal();
  }

  Future<void> deleteAccount() async {
    await request('me', method: 'DELETE', authenticated: true);
    await clearLocal();
  }

  Future<void> clearLocal() async {
    _generation++;
    _token = null;
    user = null;
    biometric = false;
    locked = false;
    await _withStorage(() async {
      await _storage.delete(key: tokenKey);
      await _storage.delete(key: biometricKey);
    });
    notifyListeners();
  }
}

class AccountException implements Exception {
  const AccountException(this.code);
  final String code;
  @override
  String toString() => code;
}
