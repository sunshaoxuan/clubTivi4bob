import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_diagnostics.dart';

/// Stable, app-scoped desktop client identity. Raw machine identifiers are
/// never stored or transmitted by this service.
class ClientFingerprintService {
  ClientFingerprintService._();

  static final instance = ClientFingerprintService._();
  static final _format = RegExp(r'^btv1_[0-9a-f]{64}$');
  static const _fallbackKey = 'bobtv_install_fingerprint_v1';

  Future<String?>? _initialization;
  String? _current;

  String? get current => _current;
  String? get apiFingerprint => _current?.substring(5);

  Future<String?> initialize() => _initialization ??= _initialize();

  Future<String?> _initialize() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(_fallbackKey);
      if (saved != null && _format.hasMatch(saved)) {
        _current = saved;
        return saved;
      }
    } catch (_) {}
    if (Platform.isMacOS) return _loadOrCreateMacFingerprint();
    if (!Platform.isWindows) return _loadOrCreateFallback();
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) {
      return _loadOrCreateFallback();
    }

    try {
      final directory = Directory(p.join(localAppData, 'HotelTV', 'Identity'));
      await directory.create(recursive: true);
      final script = File(p.join(directory.path, 'ensure_fingerprint.ps1'));
      final source = await rootBundle.loadString(
        'assets/identity/ensure_fingerprint.ps1',
      );
      await script.writeAsBytes(
        [0xef, 0xbb, 0xbf, ...utf8.encode(source)],
        flush: true,
      );
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script.path,
        ],
        runInShell: false,
      ).timeout(const Duration(seconds: 20));
      if (result.exitCode != 0) {
        throw StateError('Client fingerprint setup failed: ${result.exitCode}');
      }
      final file = File(p.join(directory.path, 'client_fingerprint.txt'));
      final value = (await file.readAsString()).trim().toLowerCase();
      if (!_format.hasMatch(value)) {
        throw const FormatException('Invalid client fingerprint');
      }
      _current = value;
      try {
        await (await SharedPreferences.getInstance()).setString(
          _fallbackKey, value,
        );
      } catch (_) {}
      AppDiagnostics.instance.log('client_fingerprint_ready');
      return value;
    } catch (error, stackTrace) {
      AppDiagnostics.instance.recordError(
        'client_fingerprint', error, stackTrace,
      );
      return _loadOrCreateFallback();
    }
  }

  Future<String?> _loadOrCreateMacFingerprint() async {
    try {
      final support = await getApplicationSupportDirectory();
      final directory = Directory(p.join(support.path, 'Identity'));
      await directory.create(recursive: true);
      final file = File(p.join(directory.path, 'client_fingerprint.txt'));
      if (await file.exists()) {
        final saved = (await file.readAsString()).trim().toLowerCase();
        if (_format.hasMatch(saved)) {
          _current = saved;
          return saved;
        }
      }

      // IOPlatformUUID is independent of the host name, network interfaces,
      // MAC address and current IP. A random installation salt prevents the
      // raw hardware identifier from being recoverable from the API value.
      final result = await Process.run('/usr/sbin/ioreg', [
        '-rd1', '-c', 'IOPlatformExpertDevice',
      ]).timeout(const Duration(seconds: 8));
      final match = result.exitCode == 0
          ? RegExp(r'"IOPlatformUUID"\s*=\s*"([0-9A-Fa-f-]{36})"')
              .firstMatch(result.stdout.toString())
          : null;
      final machineId = match?.group(1)?.toLowerCase();
      if (machineId == null ||
          machineId == '00000000-0000-0000-0000-000000000000' ||
          machineId == 'ffffffff-ffff-ffff-ffff-ffffffffffff') {
        return _loadOrCreateFallback();
      }
      final random = Random.secure();
      final salt = List<int>.generate(32, (_) => random.nextInt(256));
      final payload = utf8.encode('BobTV-client-v1|macos:$machineId|') + salt;
      final value = 'btv1_${sha256.convert(payload)}';
      final temporary = File('${file.path}.${pid}.tmp');
      await temporary.writeAsString(value, flush: true);
      await temporary.rename(file.path);
      _current = value;
      try {
        await (await SharedPreferences.getInstance()).setString(
          _fallbackKey, value,
        );
      } catch (_) {}
      AppDiagnostics.instance.log('client_fingerprint_ready');
      return value;
    } catch (error, stackTrace) {
      AppDiagnostics.instance.recordError(
        'client_fingerprint_mac', error, stackTrace,
      );
      return _loadOrCreateFallback();
    }
  }

  Future<String?> _loadOrCreateFallback() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var value = prefs.getString(_fallbackKey);
      if (value == null || !_format.hasMatch(value)) {
        final random = Random.secure();
        final bytes = List<int>.generate(32, (_) => random.nextInt(256));
        value = 'btv1_${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
        await prefs.setString(_fallbackKey, value);
      }
      _current = value;
      return value;
    } catch (error, stackTrace) {
      AppDiagnostics.instance.recordError(
        'client_fingerprint_fallback', error, stackTrace,
      );
      return null;
    }
  }
}
