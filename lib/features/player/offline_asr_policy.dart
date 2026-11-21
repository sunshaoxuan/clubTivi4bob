/// One bounded PCM window. The recognition locale comes from the audio track,
/// never from the app language or the requested display subtitle language.
typedef OfflineAsrRequest = ({String pcmPath, String? audioLocale});

/// Implementations must use only the supplied PCM and keep inference on-device.
/// The system implementation must return null when it cannot guarantee those
/// conditions, including when the requested language asset is unavailable.
typedef OfflineAsrRecognize<T extends Object> =
    Future<T?> Function(OfflineAsrRequest request);

/// A bare Chinese language tag does not identify the spoken variety.
String? cjkQaAudioLocale(String? value) {
  final tag = value?.trim().toLowerCase().replaceAll('_', '-');
  if (tag == null) return null;
  if (tag == 'yue' || tag.startsWith('yue-') || tag == 'cantonese') {
    return 'yue-HK';
  }
  if (tag == 'cmn' || tag.startsWith('cmn-') || tag == 'mandarin') {
    return 'zh-CN';
  }
  return null;
}

/// Script and region tags by themselves cannot distinguish Mandarin from
/// Cantonese. Let the QA model detect the spoken language in these cases.
bool isUnspecifiedChineseSpeech(String? value) {
  final tag = value?.trim().toLowerCase().replaceAll('_', '-');
  return const {'zh', 'zho', 'chi', 'chinese'}.contains(tag) ||
      (tag?.startsWith('zh-') ?? false);
}

/// Try the device recognizer first, then a local multilingual worker.
///
/// Providers return null for unavailable or unusable output. A successful
/// empty transcript (silence) is valid and does not run a second recognizer.
/// Provider failures must be handled by the provider only after it has stopped
/// consuming PCM. The owner of the window can then safely reuse or delete it.
Future<T?> recognizeOffline<T extends Object>(
  OfflineAsrRequest request, {
  required OfflineAsrRecognize<T> system,
  required OfflineAsrRecognize<T> whisper,
  required bool Function() isCurrent,
}) async {
  if (!isCurrent()) return null;
  // System providers generally need a known locale; a multilingual worker can
  // detect an unknown audio language.
  if (request.audioLocale != null && request.audioLocale!.isNotEmpty) {
    final result = await system(request);
    if (!isCurrent()) return null;
    if (result != null) return result;
  }
  final result = await whisper(request);
  return isCurrent() ? result : null;
}
