import 'dart:io';
import 'package:flutter/services.dart';

/// Apple APIs are registered only in the iOS application, never downloaded.
class IosNativeMedia {
  static const channel = MethodChannel('bobtv/native_media');
  static Map<String, dynamic> capabilities = {};
  static Future<void> refresh({bool authorize = false}) async {
    if (!Platform.isIOS) return;
    capabilities =
        await channel.invokeMapMethod<String, dynamic>(
          authorize ? 'authorizeSpeech' : 'capabilities',
        ) ??
        {};
  }

  static bool get offlineReady =>
      capabilities['speechAuthorization'] == 3 &&
      capabilities['offlineSpeech'] == true &&
      capabilities['pcmFilter'] == true &&
      capabilities['nativeRemux'] == true;

  static Future<Map<String, dynamic>> recognize(
    String path,
    String? locale, {
    required String id,
  }) async {
    return await channel.invokeMapMethod<String, dynamic>('recognize', {
          'path': path,
          'locale': locale,
          'id': id,
        }) ??
        {};
  }
}

/// File duration can arrive after the first decoded frame. Keep explicit movie
/// files seekable during this window instead of reopening them at the beginning.
bool iosNeedsLiveReopen(String url, Duration duration) {
  final path = Uri.tryParse(url.split('|').first)?.path ?? '';
  final fileVideo = RegExp(
    r'\.(mp4|m4v|mov)$',
    caseSensitive: false,
  ).hasMatch(path);
  return !fileVideo && duration <= const Duration(minutes: 5);
}
