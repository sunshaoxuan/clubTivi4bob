/// Validate the whole requested suffix before appending to a saved APK.
class ApkDownloadPolicy {
  static int initialOffset({
    required int statusCode,
    required String? contentRange,
    required int requestedOffset,
    required int totalBytes,
    required int contentLength,
  }) {
    if (statusCode == 200) {
      if (contentLength >= 0 && contentLength != totalBytes) {
        throw const FormatException('APK response length mismatch');
      }
      return 0;
    }
    final match = RegExp(
      r'^bytes (\d+)-(\d+)/(\d+)$',
    ).firstMatch(contentRange ?? '');
    if (statusCode != 206 ||
        match == null ||
        int.parse(match[1]!) != requestedOffset ||
        int.parse(match[2]!) != totalBytes - 1 ||
        int.parse(match[3]!) != totalBytes ||
        (contentLength >= 0 && contentLength != totalBytes - requestedOffset)) {
      throw const FormatException('APK partial response mismatch');
    }
    return requestedOffset;
  }
}
