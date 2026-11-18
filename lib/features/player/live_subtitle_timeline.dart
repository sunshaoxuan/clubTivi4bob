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
    if (data['windows'] is! List || (data['windows'] as List).length > 5000) {
      throw const FormatException('Invalid subtitle window count');
    }
    final windows = (data['windows'] as List)
        .map((w) => Map<String, dynamic>.from(w as Map))
        .toList();
    double end = -double.infinity;
    var cueCount = 0;
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
      if (window['state'] != 'LOCKED') continue;
      final tracks = window['tracks'];
      if (tracks is! List || tracks.length > 32) {
        throw const FormatException('Invalid subtitle tracks');
      }
      for (final track in tracks) {
        if (track is! Map ||
            track['cues'] is! List ||
            (track['language'] != null && track['language'] is! String)) {
          throw const FormatException('Invalid subtitle track');
        }
        for (final cue in track['cues'] as List) {
          if (++cueCount > 20000 ||
              cue is! Map ||
              cue['start'] is! num ||
              cue['end'] is! num ||
              !(cue['start'] as num).isFinite ||
              !(cue['end'] as num).isFinite ||
              (cue['end'] as num) <= (cue['start'] as num) ||
              cue['text'] is! String ||
              (cue['text'] as String).length > 8192) {
            throw const FormatException('Invalid subtitle cue');
          }
        }
      }
    }
    return LiveSubtitleTimeline(session, source, windows);
  }

  Map<String, dynamic>? windowAt(double position) {
    if (!position.isFinite) return null;
    return windows
        .where(
          (w) =>
              position >= (w['start'] as num) && position < (w['end'] as num),
        )
        .firstOrNull;
  }

  String? variantLanguageAt(double position, String id) {
    final window = windowAt(position);
    if (window?['state'] != 'LOCKED') return null;
    for (final track
        in (window?['tracks'] as List? ?? const []).whereType<Map>()) {
      if (track['variantId'] == id && track['verified'] == true) {
        return track['language'] as String?;
      }
    }
    return null;
  }

  /// Evaluated against decoded playback time, never against the network edge.
  /// Each interval must carry its own confirmed programme and source asset.
  String textAt(double position, String language, {String? variantId}) {
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
            (variantId == null || t['variantId'] == variantId) &&
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
