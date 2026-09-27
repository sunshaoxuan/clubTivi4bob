import 'dart:convert';

/// Converts local diagnostics to the public API's narrow, non-sensitive shape.
class BobTvLogProjection {
  static const _allowed = <String>{
    'time', 'event', 'source', 'fatal', 'uptimeSeconds',
    'rssBytes', 'maxRssBytes', 'platform',
  };

  static List<int> project(Iterable<String> rawLines) {
    final projected = <String>[];
    var byteCount = 0;
    for (final raw in rawLines) {
      if (projected.length >= 5000) break;
      Map<dynamic, dynamic> input;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        input = decoded;
      } catch (_) {
        continue;
      }
      final time = input['time'];
      final event = input['event'];
      if (time is! String || event is! String ||
          DateTime.tryParse(time) == null ||
          !_safeTag.hasMatch(event)) continue;
      final output = <String, Object>{
        'time': _truncate(time, 256),
        'event': _truncate(event, 256),
      };
      for (final field in _allowed) {
        if (field == 'time' || field == 'event') continue;
        final value = input[field];
        if (value == null) continue;
        if (field == 'source' || field == 'platform') {
          if (value is String && _safeTag.hasMatch(value)) {
            output[field] = _truncate(value, 256);
          }
        } else if (field == 'fatal') {
          if (value is bool) output[field] = value;
        } else if (value is num && value.isFinite && value >= 0) {
          output[field] = value;
        }
      }
      final line = jsonEncode(output);
      if (line.length > 4096) continue;
      final nextBytes = utf8.encode('$line\n').length;
      if (byteCount + nextBytes > 1024 * 1024) break;
      projected.add(line);
      byteCount += nextBytes;
    }
    return utf8.encode(projected.map((line) => '$line\n').join());
  }

  static final _safeTag = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,255}$');
  static String _truncate(String value, int length) =>
      value.length <= length ? value : value.substring(0, length);
}
