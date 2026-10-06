import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'bobtv_api_client.dart';

/// Independent of installation preferences and channel-sync identity.
class HostFingerprintService {
  static String? derive(String platform, String uuid) {
    if (platform != 'windows' && platform != 'macos') return null;
    final value = uuid.trim().toLowerCase();
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(value)) {
      return null;
    }
    final compact = value.replaceAll('-', '');
    if (compact == '0' * 32 ||
        compact == 'f' * 32 ||
        value == '03000200-0400-0500-0006-000700080009') {
      return null;
    }
    final digest = sha256.convert(utf8.encode('BobTV-host-v1|$value'));
    return 'bth1_$digest';
  }

  static Future<String?> _readUuid(String platform) async {
    final process = platform == 'windows'
        ? await Process.start(
            '${Platform.environment["SystemRoot"] ?? r"C:\Windows"}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
            [
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              r'(Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop).UUID',
            ],
          )
        : await Process.start('/usr/sbin/ioreg', [
            '-rd1',
            '-c',
            'IOPlatformExpertDevice',
          ]);
    try {
      final result = await Future.wait<Object?>([
        process.exitCode,
        utf8.decoder.bind(process.stdout).join(),
        process.stderr.drain<void>(),
      ]).timeout(const Duration(seconds: 8));
      final code = result[0] as int;
      final text = result[1] as String;
      if (code != 0) return null;
      return parseUuid(platform, text);
    } finally {
      process.kill();
    }
  }

  static String? parseUuid(String platform, String output) {
    if (platform == 'windows') return output.trim();
    if (platform != 'macos') return null;
    return RegExp(
      r'"IOPlatformUUID"\s*=\s*"([0-9A-Fa-f-]{36})"',
    ).firstMatch(output)?.group(1);
  }

  static Future<void> register({
    String? platform,
    Future<String?> Function(String)? readUuid,
    BobTvApiClient? api,
    Future<void> Function(Duration)? delay,
  }) async {
    final os = platform ?? Platform.operatingSystem;
    if (os != 'windows' && os != 'macos') return;
    BobTvApiClient? client;
    try {
      final uuid = await (readUuid ?? _readUuid)(os);
      if (uuid == null) return;
      final fingerprint = derive(os, uuid);
      if (fingerprint == null) return;
      client = api ?? BobTvApiClient();
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await client.registerHost(fingerprint);
          return;
        } on BobTvApiException catch (error) {
          final status = error.statusCode;
          if (status != null && status < 500) return;
        } catch (_) {
          // No hardware values or response bodies enter diagnostics.
        }
        if (attempt < 2) {
          await (delay ?? Future<void>.delayed)(
            Duration(seconds: 5 * (attempt + 1)),
          );
        }
      }
    } catch (_) {
      // Missing hardware identity leaves this host unobserved.
    } finally {
      if (api == null) client?.close();
    }
  }
}
