class PlaybackHealthSample {
  final Duration position;
  final double? cacheSeconds;
  final bool buffering;
  final bool playing;

  const PlaybackHealthSample({
    required this.position,
    required this.cacheSeconds,
    required this.buffering,
    required this.playing,
  });
}

class PlaybackStallState {
  final int stressedSamples;
  final int noProgressSamples;

  const PlaybackStallState({
    required this.stressedSamples,
    required this.noProgressSamples,
  });

  bool get shouldWarmAlternative => stressedSamples >= 2;
  bool get shouldFailover => stressedSamples >= 3;
  bool get healthy => stressedSamples == 0;
}

/// Detects a stalled live stream using cache, buffering state, and playback
/// progress. Some mpv demuxers stop exposing cache duration when a connection
/// dies, so a missing cache value must not disable failover monitoring.
class PlaybackStallDetector {
  Duration? _lastPosition;
  int _stressedSamples = 0;
  int _noProgressSamples = 0;

  void reset() {
    _lastPosition = null;
    _stressedSamples = 0;
    _noProgressSamples = 0;
  }

  PlaybackStallState add(PlaybackHealthSample sample) {
    final previousPosition = _lastPosition;
    _lastPosition = sample.position;
    final progressed =
        previousPosition == null ||
        sample.position - previousPosition >= const Duration(milliseconds: 300);

    if (progressed) {
      _noProgressSamples = 0;
    } else {
      _noProgressSamples++;
    }

    final cacheLow = sample.cacheSeconds != null && sample.cacheSeconds! < 1.0;
    final cacheUnavailableAndFrozen =
        sample.cacheSeconds == null && _noProgressSamples >= 2;
    final playbackFrozen = _noProgressSamples >= 2;
    final stoppedUnexpectedly = !sample.playing && _noProgressSamples >= 2;
    final stressed =
        sample.buffering ||
        cacheLow ||
        cacheUnavailableAndFrozen ||
        playbackFrozen ||
        stoppedUnexpectedly;

    if (stressed) {
      _stressedSamples++;
    } else {
      _stressedSamples = 0;
    }

    return PlaybackStallState(
      stressedSamples: _stressedSamples,
      noProgressSamples: _noProgressSamples,
    );
  }
}
