import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

/// Offline tools shipped with the application. No downloaded executable or
/// microphone permission is needed; unsupported bundles preserve video playback.
class ClientSubtitleRuntime {
  static String? asr, remux, model;
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
      } else if (Platform.isMacOS || Platform.isWindows) {
        final base = File(Platform.resolvedExecutable).parent;
        final root = Platform.isMacOS
            ? '${base.parent.path}/Resources/ClientASR'
            : '${base.path}/data/ClientASR';
        final suffix = Platform.isWindows ? '.exe' : '';
        asr = '$root/bobtv-client-asr$suffix';
        remux = '$root/bobtv-client-remux$suffix';
        model = '$root/ggml-base.en-q5_1.bin';
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
