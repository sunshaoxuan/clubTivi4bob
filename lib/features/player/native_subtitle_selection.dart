import 'dart:async';
import 'package:media_kit/media_kit.dart';
import 'subtitle_preferences.dart';
import 'subtitle_policy.dart';

/// One owner per decoder, including inline, prepared and multi-view players.
class NativeSubtitleSelection {
  NativeSubtitleSelection(this.player) {
    _subscription = player.stream.tracks.listen((_) => _schedule());
    SubtitlePreferences.instance.addListener(_schedule);
  }
  final Player player;
  StreamSubscription<Tracks>? _subscription;
  Future<void> _pending = Future.value();
  bool _disposed = false;
  bool external = false;

  void _schedule() {
    _pending = _pending
        .then((_) async {
          if (_disposed) return;
          final prefs = SubtitlePreferences.instance;
          final selected = prefs.enabled && !external
              ? selectSubtitle(
                  player.state.tracks.subtitle,
                  prefs.language.tag,
                  language: (track) => track.language,
                  usable: (track) =>
                      track.id != 'no' &&
                      track.id != 'auto' &&
                      !(track.title?.toLowerCase().contains('forced') ?? false),
                )
              : null;
          final next = selected ?? SubtitleTrack.no();
          if (player.state.track.subtitle != next) {
            await player.setSubtitleTrack(next);
          }
        })
        .catchError((Object _) {});
  }

  void refresh() => _schedule();

  Future<void> dispose() async {
    _disposed = true;
    SubtitlePreferences.instance.removeListener(_schedule);
    await _subscription?.cancel();
    await _pending;
  }
}
