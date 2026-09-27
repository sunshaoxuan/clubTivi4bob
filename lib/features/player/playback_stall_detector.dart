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
  bool get shouldFailover => stressedSamples >= 8;
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

    // A live stream can keep advancing with a short cache. That alone is not
    // evidence that changing routes would improve playback.
    final playbackFrozen = _noProgressSamples >= 2;
    final stoppedUnexpectedly = !sample.playing && _noProgressSamples >= 2;
    final stressed =
        sample.buffering ||
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

/// Counts brief, recovered buffering events in a rolling time window.
class RepeatedShortBufferDetector {
  RepeatedShortBufferDetector({
    this.window = const Duration(seconds: 60),
    this.minimumDuration = const Duration(milliseconds: 400),
    this.maximumDuration = const Duration(seconds: 15),
    this.requiredEvents = 3,
  });

  final Duration window;
  final Duration minimumDuration;
  final Duration maximumDuration;
  final int requiredEvents;
  final List<DateTime> _recoveredAt = [];

  void reset() => _recoveredAt.clear();

  bool addRecoveredBuffer(DateTime at, Duration duration) {
    _recoveredAt.removeWhere((time) => at.difference(time) > window);
    if (duration < minimumDuration || duration > maximumDuration) {
      return false;
    }
    _recoveredAt.add(at);
    return _recoveredAt.length >= requiredEvents;
  }
}
