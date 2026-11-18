import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

/// Retain a duration of observed media metadata when a provider switches from
/// long movie segments to short advertising segments in a fixed-size playlist.
/// Media and keys remain on their original CDN; no media is fetched here.
class HlsPlaylistHistory {
  HlsPlaylistHistory({this.seconds = 90});
  final double seconds;
  final _entries = SplayTreeMap<int, _HistorySegment>();
  int _version = 3;

  String update(String body, Uri origin) {
    final first = int.tryParse(
      RegExp(r'#EXT-X-MEDIA-SEQUENCE:(\d+)').firstMatch(body)?[1] ?? '',
    );
    if (first == null || !body.contains('#EXTINF:')) return body;
    if (body.contains('#EXT-X-ENDLIST')) {
      _entries.clear();
      return body;
    }
    final lines = const LineSplitter().convert(body);
    final firstUri = lines
        .where((line) => line.trim().isNotEmpty && !line.startsWith('#'))
        .firstOrNull;
    if (_entries.isNotEmpty &&
        (first + 900 < _entries.lastKey()! ||
            first == 0 &&
                firstUri != null &&
                _entries[0] != null &&
                _entries[0]!.uri != origin.resolve(firstUri.trim()))) {
      _entries.clear();
    }
    _version = math.max(
      _version,
      int.tryParse(
            RegExp(r'#EXT-X-VERSION:(\d+)').firstMatch(body)?[1] ?? '',
          ) ??
          3,
    );
    var sequence = first;
    var discontinuities =
        int.tryParse(
          RegExp(r'#EXT-X-DISCONTINUITY-SEQUENCE:(\d+)').firstMatch(body)?[1] ??
              '',
        ) ??
        0;
    var pendingDiscontinuities = 0;
    var tags = <String>[];
    double? duration;
    String? key = _entries[first]?.key ?? _entries[first - 1]?.key;
    String? map = _entries[first]?.map ?? _entries[first - 1]?.map;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty ||
          line == '#EXTM3U' ||
          line.startsWith('#EXT-X-VERSION:') ||
          line.startsWith('#EXT-X-TARGETDURATION:') ||
          line.startsWith('#EXT-X-MEDIA-SEQUENCE:') ||
          line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE:') ||
          line.startsWith('#EXT-X-START:')) {
        continue;
      }
      String absoluteTag(String value) => value.replaceAllMapped(
        RegExp(r'URI="([^"]+)"'),
        (match) => 'URI="${origin.resolve(match[1]!)}"',
      );
      if (line.startsWith('#EXT-X-KEY:')) {
        key = line.contains('METHOD=NONE') ? null : absoluteTag(line);
      } else if (line.startsWith('#EXT-X-MAP:')) {
        map = absoluteTag(line);
      } else if (line.startsWith('#')) {
        if (line == '#EXT-X-DISCONTINUITY') {
          discontinuities++;
          pendingDiscontinuities++;
        }
        if (line.startsWith('#EXTINF:')) {
          duration = double.tryParse(line.substring(8).split(',').first);
        }
        tags.add(absoluteTag(line));
      } else if (duration != null && duration > 0) {
        final uri = origin.resolve(line);
        int? rangeEnd;
        tags = tags.map((tag) {
          if (!tag.startsWith('#EXT-X-BYTERANGE:')) return tag;
          final parts = tag.substring(17).split('@');
          final length = int.parse(parts.first);
          final previous = _entries[sequence - 1];
          final offset = parts.length == 2
              ? int.parse(parts[1])
              : previous?.uri == uri
              ? previous?.rangeEnd ?? 0
              : 0;
          rangeEnd = offset + length;
          return '#EXT-X-BYTERANGE:$length@$offset';
        }).toList();
        final previous = _entries[sequence];
        if (previous == null || previous.uri != uri) {
          _entries[sequence] = _HistorySegment(
            uri,
            duration,
            List.unmodifiable(tags),
            key,
            map,
            discontinuities - pendingDiscontinuities,
            rangeEnd,
          );
        }
        sequence++;
        tags = [];
        duration = null;
        pendingDiscontinuities = 0;
      }
    }
    if (_entries.isEmpty) return body;
    var earliest = _entries.lastKey()!;
    var retained = _entries[earliest]!.duration;
    while (_entries.containsKey(earliest - 1) &&
        retained < seconds &&
        _entries.lastKey()! - earliest < 899) {
      retained += _entries[--earliest]!.duration;
    }
    _entries.removeWhere((sequence, _) => sequence < earliest);
    final target = _entries.values
        .map((entry) => entry.duration)
        .reduce(math.max);
    final output = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:$_version')
      ..writeln('#EXT-X-TARGETDURATION:${target.ceil()}')
      ..writeln('#EXT-X-MEDIA-SEQUENCE:$earliest')
      ..writeln(
        '#EXT-X-DISCONTINUITY-SEQUENCE:${_entries[earliest]!.discontinuitiesBefore}',
      );
    String? activeKey, activeMap;
    for (final entry in _entries.values) {
      if (entry.key != activeKey) {
        output.writeln(entry.key ?? '#EXT-X-KEY:METHOD=NONE');
        activeKey = entry.key;
      }
      if (entry.map != activeMap && entry.map != null) {
        output.writeln(entry.map);
        activeMap = entry.map;
      }
      for (final tag in entry.tags) {
        output.writeln(tag);
      }
      output.writeln(entry.uri);
    }
    return output.toString();
  }
}

class _HistorySegment {
  const _HistorySegment(
    this.uri,
    this.duration,
    this.tags,
    this.key,
    this.map,
    this.discontinuitiesBefore,
    this.rangeEnd,
  );
  final Uri uri;
  final double duration;
  final List<String> tags;
  final String? key, map;
  final int discontinuitiesBefore;
  final int? rangeEnd;
}
