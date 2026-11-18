import 'dart:math' as math;
import 'dart:typed_data';

typedef PcmChunk = ({double start, Uint8List bytes});

class PcmWindow {
  const PcmWindow(this.start, this.bytes, this.gapSeconds);
  final double start, gapSeconds;
  final Uint8List bytes;
  double get duration => bytes.length / 32000;
  double get end => start + duration;
}

/// Preserve the decoder's real sample timeline when a busy client misses a tap.
/// Missing PCM is silent padding; subsequent dialogue never moves earlier.
PcmWindow? buildPcmWindow(List<PcmChunk> chunks) {
  if (chunks.isEmpty) return null;
  final start = chunks.first.start;
  if (!start.isFinite) throw const FormatException('Invalid audio clock');
  final output = BytesBuilder(copy: false);
  var gapBytes = 0;
  for (final chunk in chunks) {
    if (!chunk.start.isFinite || chunk.bytes.length.isOdd) {
      throw const FormatException('Invalid PCM chunk');
    }
    final offset = ((chunk.start - start) * 16000).round() * 2;
    if (offset < 0 || offset + chunk.bytes.length > 40 * 32000) {
      throw const FormatException('Audio window exceeds its clock bounds');
    }
    if (offset > output.length) {
      final gap = offset - output.length;
      output.add(Uint8List(gap));
      gapBytes += gap;
    }
    final skip = math.max(0, output.length - offset);
    if (skip < chunk.bytes.length) {
      output.add(Uint8List.sublistView(chunk.bytes, skip));
    }
  }
  return PcmWindow(start, output.takeBytes(), gapBytes / 32000);
}

/// Reserve playback for measured recognition cost, including slower devices.
class SpeechPlaybackBudget {
  final _recentCosts = <double>[];

  void record(double audioSeconds, double processSeconds) {
    if (!audioSeconds.isFinite ||
        !processSeconds.isFinite ||
        audioSeconds <= 0 ||
        processSeconds <= 0) {
      return;
    }
    _recentCosts.add(processSeconds / audioSeconds);
    if (_recentCosts.length > 3) _recentCosts.removeAt(0);
  }

  double minimumSeconds(double audioSeconds, {required bool cold}) {
    final floor = cold ? 24.0 : 8.0;
    if (_recentCosts.isEmpty) return floor;
    final cost = _recentCosts.reduce(math.max);
    return math.max(floor, audioSeconds * cost * 1.25 + 2).clamp(8, 30);
  }

  double recoveryTimeoutSeconds(double audioSeconds) {
    final cost = _recentCosts.isEmpty ? 1.0 : _recentCosts.reduce(math.max);
    return (audioSeconds * cost * 1.5 + 5).clamp(15, 40);
  }
}
