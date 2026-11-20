import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

/// Offline tools shipped with the application. No downloaded executable or
/// microphone permission is needed; unsupported bundles preserve video playback.
class ClientSubtitleRuntime {
  static String? asr, remux, model, systemAsr;
  static Future<void>? _initialization;
  static bool get available => asr != null && remux != null && model != null;
  static Future<void> initialize() => _initialization ??= _load();

  static Future<void> _load() async {
    try {
      if (Platform.isAndroid) {
        final paths = await const MethodChannel('bobtv/client_subtitles')
            .invokeMapMethod<String, String>('resources')
            .timeout(const Duration(seconds: 15));
        asr = paths?['asr'];
        remux = paths?['remux'];
        model = paths?['model'];
        final fast = paths?['asrFast'];
        if (asr != null && fast != null) {
          final capability = await Process.run(asr!, [
            '--capabilities',
          ]).timeout(const Duration(seconds: 3));
          if (capability.exitCode == 0 &&
              jsonDecode(capability.stdout as String)['avx2'] == true) {
            asr = fast;
          } else if (paths?['tinyModel'] != null) {
            model = paths!['tinyModel'];
          }
        }
        if (paths?['preferTiny'] == 'true' && paths?['tinyModel'] != null) {
          model = paths!['tinyModel'];
        }
      } else if (Platform.isMacOS || Platform.isWindows) {
        final base = File(Platform.resolvedExecutable).parent;
        final root = Platform.isMacOS
            ? '${base.parent.path}/Resources/ClientASR'
            : '${base.path}/data/ClientASR';
        final suffix = Platform.isWindows ? '.exe' : '';
        asr = '$root/bobtv-client-asr$suffix';
        remux = '$root/bobtv-client-remux$suffix';
        final multilingual = await File('$root/ggml-base-q5_1.bin').exists();
        final variant = multilingual ? '' : '.en';
        model = '$root/ggml-base$variant-q5_1.bin';
        final system = File('$root/bobtv-system-asr$suffix');
        if (await system.exists()) systemAsr = system.path;
        if (Platform.isWindows &&
            await File('$root/bobtv-client-asr-avx2.exe').exists()) {
          final capability = await Process.run(asr!, [
            '--capabilities',
          ]).timeout(const Duration(seconds: 3));
          if (capability.exitCode == 0 &&
              jsonDecode(capability.stdout as String)['avx2'] == true) {
            asr = '$root/bobtv-client-asr-avx2.exe';
          } else if (await File('$root/ggml-tiny$variant-q5_1.bin').exists()) {
            model = '$root/ggml-tiny$variant-q5_1.bin';
          }
        }
      }
      if (!available ||
          !await File(asr!).exists() ||
          !await File(remux!).exists() ||
          !await File(model!).exists()) {
        asr = remux = model = null;
      }
    } on Object {
      asr = remux = model = null;
    }
  }
}
