import 'subtitle_policy.dart';

class LiveSubtitleTimeline {
  LiveSubtitleTimeline(this.session, this.source, this.windows);
  final String session;
  final String source;
  final List<Map<String, dynamic>> windows;

  factory LiveSubtitleTimeline.decode(
    Map<String, dynamic> data, {
    required String session,
    required String source,
  }) {
    if (data['session'] != session || data['source'] != source) {
      throw const FormatException('Subtitle session identity mismatch');
    }
    final windows = (data['windows'] as List)
        .map((w) => Map<String, dynamic>.from(w as Map))
        .toList();
    double end = -double.infinity;
    for (final window in windows) {
      final start = (window['start'] as num).toDouble();
      final nextEnd = (window['end'] as num).toDouble();
      if (!start.isFinite ||
          !nextEnd.isFinite ||
          start < end ||
          nextEnd <= start) {
        throw const FormatException('Invalid subtitle timeline');
      }
      end = nextEnd;
    }
    return LiveSubtitleTimeline(session, source, windows);
  }

  /// Evaluated against decoded playback time, never against the network edge.
  /// Each interval must carry its own confirmed programme and source asset.
  String textAt(double position, String language) {
    if (!position.isFinite) return '';
    for (final window in windows) {
      if (position < (window['start'] as num) ||
          position >= (window['end'] as num)) {
        continue;
      }
      if (window['state'] != 'LOCKED' ||
          (window['program'] as String? ?? '').isEmpty ||
          (window['asset'] as String? ?? '').isEmpty) {
        return '';
      }
      final tracks = (window['tracks'] as List? ?? const []).map(
        (t) => Map<String, dynamic>.from(t as Map),
      );
      final track = selectSubtitle(
        tracks,
        language,
        language: (t) => t['language'] as String?,
        usable: (t) =>
            t['verified'] == true &&
            (t['cues'] as List? ?? const []).isNotEmpty,
      );
      if (track == null) return '';
      final text = <String>[];
      for (final raw in track['cues'] as List) {
        final cue = raw as Map;
        final start = (cue['start'] as num).toDouble();
        final end = (cue['end'] as num).toDouble();
        if (start.isFinite &&
            end.isFinite &&
            position >= start &&
            position < end) {
          final value = cue['text'];
          if (value is String && value.trim().isNotEmpty) {
            text.add(value.trim());
          }
        }
      }
      return text.join('\n');
    }
    return '';
  }
}
