import 'dart:async';

typedef SubtitlePlaybackSample = ({
  bool playing,
  bool buffering,
  Duration position,
});

/// Drives only a background subtitle candidate. Playback health comes from
/// decoded progress on the active route, without a separate upstream probe.
class SubtitleMediaRecovery {
  SubtitleMediaRecovery({
    required this.sample,
    required this.enabled,
    required this.warm,
  });

  final SubtitlePlaybackSample Function() sample;
  final bool Function() enabled;
  final Future<bool> Function() warm;
  Timer? _timer;
  Duration? _previousPosition;
  int _advancing = 0, _failures = 0, _backoffTicks = 0, _generation = 0;
  bool _pending = false;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void cancel() {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    _previousPosition = null;
    _advancing = _failures = _backoffTicks = 0;
    _pending = false;
  }

  void _tick() {
    if (_pending) return;
    if (_backoffTicks > 0) --_backoffTicks;
    final state = sample();
    if (!enabled() || !state.playing || state.buffering) {
      _previousPosition = null;
      _advancing = 0;
      return;
    }
    final previous = _previousPosition;
    _previousPosition = state.position;
    final delta = previous == null ? null : state.position - previous;
    if (delta == null ||
        delta < const Duration(milliseconds: 350) ||
        delta > const Duration(seconds: 3)) {
      _advancing = 0;
      return;
    }
    if (++_advancing >= 2 && _backoffTicks == 0) {
      _pending = true;
      unawaited(_attempt(_generation));
    }
  }

  Future<void> _attempt(int generation) async {
    var recovered = false;
    try {
      recovered = await warm();
    } catch (_) {
      // The current route stays in use while a later candidate is tried.
    }
    if (generation != _generation) return;
    if (recovered) {
      cancel();
      return;
    }
    _pending = false;
    _previousPosition = null;
    _advancing = 0;
    const backoff = [2, 4, 8, 16, 30];
    _backoffTicks = backoff[_failures];
    if (_failures < backoff.length - 1) ++_failures;
  }
}
