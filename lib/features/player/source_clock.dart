import 'dart:math' as math;

/// Relative source-time corrections from the local decoder-free remuxer.
/// Stream/PID replacement and packet repair invalidate this optional evidence.
class SourceClockLedger {
  int _epoch = 0;
  bool _usable = true;
  final _rows = <int, List<({double at, double removed})>>{};

  void reset() {
    _epoch++;
    _usable = true;
    _rows.clear();
  }

  void invalidate() => _usable = false;

  void observe(Map<String, dynamic> event) {
    final kind = event['event'];
    if (kind == 'remux_stream_changed' ||
        kind == 'remux_packet_adjusted' ||
        kind == 'remux_error') {
      invalidate();
      return;
    }
    if (kind != 'remux_discontinuity') return;
    final stream = event['stream'];
    final at = event['outputDts'];
    final delta = event['removedSeconds'];
    if (stream is! int ||
        !const {0, 1}.contains(stream) ||
        at is! num ||
        delta is! num ||
        !at.isFinite ||
        !delta.isFinite ||
        at < 0 ||
        at > 1209600 ||
        delta.abs() > 1209600) {
      invalidate();
      return;
    }
    final rows = _rows.putIfAbsent(stream, () => []);
    if (rows.isNotEmpty && at < rows.last.at) {
      invalidate();
      return;
    }
    rows.add((
      at: at.toDouble(),
      removed: (rows.lastOrNull?.removed ?? 0) + delta,
    ));
  }

  Map<String, Object?>? at(double position) {
    if (!_usable || !position.isFinite || position < 0) return null;
    ({double at, double removed}) latest(int stream) {
      for (final row in (_rows[stream] ?? []).reversed) {
        if (row.at <= position + .01) return row;
      }
      return (at: 0, removed: 0);
    }

    final a = latest(0), b = latest(1);
    return {
      'epoch': _epoch,
      'videoRemoved': a.removed,
      'audioRemoved': b.removed,
      'updatedAt': math.min(a.at, b.at),
      'boundaryAt': math.max(a.at, b.at),
    };
  }
}

/// A fresh AV transition next to a known upcoming advert clears captions at
/// render time, including manifest clocks that trail actual packets. Looking
/// ahead alone never pauses subtitles; the transition must be within a 250 ms render safety margin.
bool sourceBoundaryBeforeAdvert(
  Map<String, Object?>? clock,
  double position, {
  required bool advertWithinLookahead,
}) {
  final boundary = clock?['boundaryAt'];
  return advertWithinLookahead &&
      boundary is num &&
      boundary > 0 &&
      boundary <= position + .25 &&
      position - boundary < 30;
}
